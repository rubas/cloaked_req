defmodule CloakedReq.AdapterTest do
  @moduledoc """
  Verifies Req adapter integration, option wiring, and non-network validation behavior.
  """

  use ExUnit.Case, async: true

  alias CloakedReq.AdapterError
  alias CloakedReq.Error
  alias CloakedReq.Request
  alias CloakedReq.Response

  doctest AdapterError, import: false

  # -------------------------------------------------------------------
  # Public API wiring
  # -------------------------------------------------------------------

  test "attach/2 configures adapter and custom options" do
    request = [url: "https://example.com"] |> Req.new() |> CloakedReq.attach(impersonate: :chrome_136)

    assert is_function(request.adapter, 1)
    assert Req.Request.get_option(request, :impersonate) == :chrome_136
  end

  test "impersonate/2 sets profile option and adapter" do
    request = [url: "https://example.com"] |> Req.new() |> CloakedReq.impersonate(:firefox_136)

    assert Req.Request.get_option(request, :impersonate) == :firefox_136
    assert is_function(request.adapter, 1)
  end

  # -------------------------------------------------------------------
  # Req bridge: to_native_payload/1
  # -------------------------------------------------------------------

  test "req bridge maps Req request into native payload" do
    request =
      [url: "https://example.com", method: :post, headers: [{"x-demo", "1"}], body: "payload"]
      |> Req.new()
      |> CloakedReq.attach(impersonate: :chrome_136, insecure_skip_verify: true)

    assert {:ok, payload} = Request.to_native_payload(request)
    assert payload["method"] == "POST"
    assert payload["url"] == "https://example.com"
    assert payload["body_base64"] == Base.encode64("payload")
    assert payload["emulation"] == "chrome_136"
    assert payload["insecure_skip_verify"]
    assert ["x-demo", "1"] in payload["headers"]
  end

  test "req bridge rejects streaming into adapters" do
    request =
      [url: "https://example.com", into: fn _chunk, acc -> {:cont, acc} end]
      |> Req.new()
      |> CloakedReq.attach()

    assert {:error, %Error{type: :invalid_request, message: "streaming into is not supported by CloakedReq adapter"}} =
             Request.to_native_payload(request)
  end

  test "adapter returns adapter error on unsupported request shape" do
    request =
      [url: "https://example.com", into: fn _chunk, acc -> {:cont, acc} end]
      |> Req.new()
      |> CloakedReq.attach()

    assert {^request, %AdapterError{} = exception} = CloakedReq.run(request)
    assert exception.message == "invalid_request: streaming into is not supported by CloakedReq adapter"
    assert %Error{type: :invalid_request} = exception.error
  end

  # -------------------------------------------------------------------
  # URL validation
  # -------------------------------------------------------------------

  test "relative URL (missing scheme/host) returns error" do
    request =
      [url: "https://example.com"]
      |> Req.new()
      |> CloakedReq.attach()

    request = %{request | url: URI.parse("/relative/path")}

    assert {:error, %Error{type: :invalid_request, message: "url must be an absolute http(s) URL"}} =
             Request.to_native_payload(request)
  end

  test "unsupported scheme returns error" do
    request =
      [url: "https://example.com"]
      |> Req.new()
      |> CloakedReq.attach()

    request = %{request | url: URI.parse("ftp://example.com/file")}

    assert {:error, %Error{type: :invalid_request, message: "url must be an absolute http(s) URL"}} =
             Request.to_native_payload(request)
  end

  # -------------------------------------------------------------------
  # Impersonate option validation
  # -------------------------------------------------------------------

  test "non-atom impersonate value returns error" do
    request =
      [url: "https://example.com"]
      |> Req.new()
      |> CloakedReq.attach(impersonate: "chrome_136")

    assert {:error, %Error{type: :invalid_request, message: "impersonate must be a profile atom"}} =
             Request.to_native_payload(request)
  end

  # -------------------------------------------------------------------
  # Timeout validation
  # -------------------------------------------------------------------

  test "infinity receive_timeout returns error" do
    request =
      [url: "https://example.com", receive_timeout: :infinity]
      |> Req.new()
      |> CloakedReq.attach()

    assert {:error, %Error{type: :invalid_request, message: "receive_timeout must be a positive integer"}} =
             Request.to_native_payload(request)
  end

  test "zero receive_timeout returns error" do
    request =
      [url: "https://example.com", receive_timeout: 0]
      |> Req.new()
      |> CloakedReq.attach()

    assert {:error, %Error{type: :invalid_request, message: "receive_timeout must be a positive integer"}} =
             Request.to_native_payload(request)
  end

  test "negative receive_timeout returns error" do
    request =
      [url: "https://example.com", receive_timeout: -1]
      |> Req.new()
      |> CloakedReq.attach()

    assert {:error, %Error{type: :invalid_request, message: "receive_timeout must be a positive integer"}} =
             Request.to_native_payload(request)
  end

  test "string receive_timeout returns error" do
    request =
      [url: "https://example.com"]
      |> Req.new()
      |> CloakedReq.attach()

    request = Req.Request.put_option(request, :receive_timeout, "5000")

    assert {:error, %Error{type: :invalid_request, message: "receive_timeout must be a positive integer"}} =
             Request.to_native_payload(request)
  end

  # -------------------------------------------------------------------
  # insecure_skip_verify validation
  # -------------------------------------------------------------------

  test "non-boolean insecure_skip_verify returns error" do
    request =
      [url: "https://example.com"]
      |> Req.new()
      |> CloakedReq.attach(insecure_skip_verify: "yes")

    assert {:error, %Error{type: :invalid_request, message: "insecure_skip_verify must be a boolean"}} =
             Request.to_native_payload(request)
  end

  # -------------------------------------------------------------------
  # Body encoding
  # -------------------------------------------------------------------

  test "iodata body (list of binaries) is accepted" do
    request =
      [url: "https://example.com", method: :post, body: ["hello", " ", "world"]]
      |> Req.new()
      |> CloakedReq.attach()

    assert {:ok, payload} = Request.to_native_payload(request)
    assert payload["body_base64"] == Base.encode64("hello world")
  end

  test "non-iodata body (integer) returns error" do
    request =
      [url: "https://example.com", method: :post]
      |> Req.new()
      |> CloakedReq.attach()

    request = %{request | body: 42}

    assert {:error, %Error{type: :invalid_request, message: "request body must be binary or iodata"}} =
             Request.to_native_payload(request)
  end

  test "nil body produces null body_base64" do
    request =
      [url: "https://example.com"]
      |> Req.new()
      |> CloakedReq.attach()

    assert {:ok, payload} = Request.to_native_payload(request)
    assert payload["body_base64"] == nil
  end

  # -------------------------------------------------------------------
  # max_body_size option validation
  # -------------------------------------------------------------------

  test "non-integer max_body_size returns error" do
    request =
      [url: "https://example.com"]
      |> Req.new()
      |> CloakedReq.attach(max_body_size: "big")

    assert {:error, %Error{type: :invalid_request, message: "max_body_size must be a positive integer or :unlimited"}} =
             Request.to_native_payload(request)
  end

  test "zero max_body_size returns error" do
    request =
      [url: "https://example.com"]
      |> Req.new()
      |> CloakedReq.attach(max_body_size: 0)

    assert {:error, %Error{type: :invalid_request, message: "max_body_size must be a positive integer or :unlimited"}} =
             Request.to_native_payload(request)
  end

  test "negative max_body_size returns error" do
    request =
      [url: "https://example.com"]
      |> Req.new()
      |> CloakedReq.attach(max_body_size: -1)

    assert {:error, %Error{type: :invalid_request, message: "max_body_size must be a positive integer or :unlimited"}} =
             Request.to_native_payload(request)
  end

  test "unlimited max_body_size produces nil in payload" do
    request =
      [url: "https://example.com"]
      |> Req.new()
      |> CloakedReq.attach(max_body_size: :unlimited)

    assert {:ok, payload} = Request.to_native_payload(request)
    assert payload["max_body_size_bytes"] == nil
  end

  test "request body exceeding max_body_size returns error" do
    request =
      [url: "https://example.com", method: :post, body: String.duplicate("x", 1000)]
      |> Req.new()
      |> CloakedReq.attach(max_body_size: 500)

    assert {:error, %Error{type: :invalid_request, message: "request body exceeds max_body_size"} = error} =
             Request.to_native_payload(request)

    assert error.details.size == 1000
    assert error.details.limit == 500
  end

  test "request body within max_body_size passes" do
    request =
      [url: "https://example.com", method: :post, body: "small"]
      |> Req.new()
      |> CloakedReq.attach(max_body_size: 1000)

    assert {:ok, payload} = Request.to_native_payload(request)
    assert payload["body_base64"] == Base.encode64("small")
  end

  test "iodata body exceeding max_body_size returns error" do
    request =
      [url: "https://example.com", method: :post, body: [String.duplicate("a", 600), String.duplicate("b", 600)]]
      |> Req.new()
      |> CloakedReq.attach(max_body_size: 1000)

    assert {:error, %Error{type: :invalid_request, message: "request body exceeds max_body_size"} = error} =
             Request.to_native_payload(request)

    assert error.details.size == 1200
    assert error.details.limit == 1000
  end

  test "default max_body_size is 10 MB in payload" do
    request =
      [url: "https://example.com"]
      |> Req.new()
      |> CloakedReq.attach()

    assert {:ok, payload} = Request.to_native_payload(request)
    assert payload["max_body_size_bytes"] == 10_485_760
  end

  # -------------------------------------------------------------------
  # Response decoding: to_req_response/1
  # -------------------------------------------------------------------

  test "to_req_response/1 rejects missing status key" do
    assert {:error, %Error{type: :invalid_native_response}} =
             Response.from_native(%{"headers" => [], "body_base64" => ""})
  end

  test "to_req_response/1 rejects non-integer status" do
    assert {:error, %Error{type: :invalid_native_response}} =
             Response.from_native(%{"status" => "200", "headers" => [], "body_base64" => ""})
  end

  test "to_req_response/1 rejects invalid base64 body" do
    assert {:error, %Error{type: :invalid_native_response, message: "body_base64 is not valid base64"}} =
             Response.from_native(%{"status" => 200, "headers" => [], "body_base64" => "###invalid###"})
  end

  test "to_req_response/1 round-trips a valid response" do
    native = %{
      "status" => 200,
      "headers" => [["content-type", "text/plain"]],
      "body_base64" => Base.encode64("ok")
    }

    assert {:ok, %Req.Response{} = response} = Response.from_native(native)
    assert response.status == 200
    assert response.body == "ok"
    assert response.headers["content-type"] == ["text/plain"]
  end
end
