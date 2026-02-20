defmodule CloakedReq.E2ETest do
  @moduledoc """
  End-to-end tests exercising the full Elixir -> NIF -> Rust wreq -> TCP pipeline.
  """

  use ExUnit.Case, async: true

  alias CloakedReq.AdapterError
  alias CloakedReq.TestServer

  test "GET returns 200 with body and response headers" do
    response = TestServer.build_response(200, [{"content-type", "text/plain"}, {"x-server", "test"}], "hello")
    {url, server} = TestServer.start(response: response)

    req = [url: url, retry: false] |> Req.new() |> CloakedReq.attach()

    assert {:ok, %Req.Response{} = resp} = Req.request(req)
    assert resp.status == 200
    assert resp.body == "hello"
    assert "test" in resp.headers["x-server"]

    raw = TestServer.get_request(server)
    assert raw =~ ~r/^GET \/ HTTP\/1\.1/
  end

  test "POST sends body and receives 201" do
    response = TestServer.build_response(201, [{"content-type", "text/plain"}], "created")
    {url, server} = TestServer.start(response: response)

    req = [url: url, method: :post, body: "hello world", retry: false] |> Req.new() |> CloakedReq.attach()

    assert {:ok, %Req.Response{} = resp} = Req.request(req)
    assert resp.status == 201
    assert resp.body == "created"

    raw = TestServer.get_request(server)
    assert raw =~ ~r/^POST \/ HTTP\/1\.1/
    assert raw =~ "hello world"
  end

  test "custom request headers reach the server" do
    response = TestServer.build_response(200, [{"content-type", "text/plain"}], "ok")
    {url, server} = TestServer.start(response: response)

    req =
      [url: url, headers: [{"x-trace-id", "abc-123"}, {"x-source", "elixir-test"}], retry: false]
      |> Req.new()
      |> CloakedReq.attach()

    assert {:ok, _resp} = Req.request(req)

    raw = TestServer.get_request(server)
    assert raw =~ ~r/x-trace-id:\s*abc-123/i
    assert raw =~ ~r/x-source:\s*elixir-test/i
  end

  test "response headers are decoded into Req.Response" do
    response =
      TestServer.build_response(
        200,
        [{"content-type", "text/plain"}, {"x-request-id", "req-456"}, {"x-powered-by", "cloaked"}],
        "ok"
      )

    {url, _server} = TestServer.start(response: response)

    req = [url: url, retry: false] |> Req.new() |> CloakedReq.attach()

    assert {:ok, %Req.Response{} = resp} = Req.request(req)
    assert "req-456" in resp.headers["x-request-id"]
    assert "cloaked" in resp.headers["x-powered-by"]
  end

  test "404 status is propagated with body" do
    response = TestServer.build_response(404, [{"content-type", "text/plain"}], "not found")
    {url, _server} = TestServer.start(response: response)

    req = [url: url, retry: false] |> Req.new() |> CloakedReq.attach()

    assert {:ok, %Req.Response{} = resp} = Req.request(req)
    assert resp.status == 404
    assert resp.body == "not found"
  end

  test "500 status is propagated with body" do
    response = TestServer.build_response(500, [{"content-type", "text/plain"}], "internal error")
    {url, _server} = TestServer.start(response: response)

    req = [url: url, retry: false] |> Req.new() |> CloakedReq.attach()

    assert {:ok, %Req.Response{} = resp} = Req.request(req)
    assert resp.status == 500
    assert resp.body == "internal error"
  end

  test "response body at exact max_body_size succeeds" do
    body = String.duplicate("x", 512)
    response = TestServer.build_response(200, [{"content-type", "text/plain"}], body)
    {url, _server} = TestServer.start(response: response)

    req = [url: url, retry: false] |> Req.new() |> CloakedReq.attach(max_body_size: 512)

    assert {:ok, %Req.Response{} = resp} = Req.request(req)
    assert resp.status == 200
    assert byte_size(resp.body) == 512
  end

  test "response exceeding max_body_size returns adapter error" do
    body = String.duplicate("x", 600)
    response = TestServer.build_response(200, [{"content-type", "text/plain"}], body)
    {url, _server} = TestServer.start(response: response)

    req = [url: url, retry: false] |> Req.new() |> CloakedReq.attach(max_body_size: 500)

    assert {:error, %AdapterError{} = error} = Req.request(req)
    assert error.error.type == :invalid_request
    assert error.error.message == "response body exceeds max_body_size"
  end

  test "server delay past receive_timeout returns transport error" do
    response = TestServer.build_response(200, [{"content-type", "text/plain"}], "late")
    {url, _server} = TestServer.start(response: response, delay_ms: 500)

    req = [url: url, receive_timeout: 100, retry: false] |> Req.new() |> CloakedReq.attach()

    assert {:error, %AdapterError{} = error} = Req.request(req)
    assert error.error.type == :transport_error
  end

  test "binary non-UTF8 body is preserved through round-trip" do
    binary_body = <<0xFF, 0xFE, 0x00, 0x01, 0x80, 0xC0>> <> :crypto.strong_rand_bytes(122)
    response = TestServer.build_response(200, [{"content-type", "application/octet-stream"}], binary_body)
    {url, _server} = TestServer.start(response: response)

    req = [url: url, retry: false, decode_body: false] |> Req.new() |> CloakedReq.attach()

    assert {:ok, %Req.Response{} = resp} = Req.request(req)
    assert resp.status == 200
    assert resp.body == binary_body
  end

  test "redirect from server A to server B returns final response" do
    # Server B (destination) returns 200
    final_response = TestServer.build_response(200, [{"content-type", "text/plain"}], "arrived")
    {dest_url, _dest_server} = TestServer.start(response: final_response)

    # Server A returns 302 redirect to server B
    redirect_response = TestServer.build_response(302, [{"location", dest_url}], "")
    {origin_url, _origin_server} = TestServer.start(response: redirect_response)

    req = [url: origin_url, retry: false] |> Req.new() |> CloakedReq.attach()

    assert {:ok, %Req.Response{} = resp} = Req.request(req)
    assert resp.status == 200
    assert resp.body == "arrived"
  end

  test "response includes url in private metadata" do
    response = TestServer.build_response(200, [{"content-type", "text/plain"}], "ok")
    {url, _server} = TestServer.start(response: response)

    req = [url: url, retry: false] |> Req.new() |> CloakedReq.attach()

    assert {:ok, %Req.Response{} = resp} = Req.request(req)
    assert is_binary(resp.private[:cloaked_req_url])
    assert resp.private[:cloaked_req_url] =~ "127.0.0.1"
  end
end
