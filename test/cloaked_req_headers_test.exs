defmodule CloakedReqHeadersTest do
  @moduledoc """
  Verifies the headers that reach the wire carry the impersonation profile and
  not Req's own defaults.
  """

  use ExUnit.Case, async: true

  alias CloakedReq.Pool
  alias CloakedReq.TestServer

  # Every header wreq emits for `:chrome_136`, in wire order, `host` excluded
  # because its value carries the ephemeral test port. Pinning the whole set
  # catches an upstream `wreq-util` change that silently alters the fingerprint.
  @chrome_136_headers [
    {"sec-ch-ua", ~s("Chromium";v="136", "Google Chrome";v="136", "Not.A/Brand";v="99")},
    {"sec-ch-ua-mobile", "?0"},
    {"sec-ch-ua-platform", ~s("macOS")},
    {"upgrade-insecure-requests", "1"},
    {"user-agent",
     "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36"},
    {"accept",
     "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7"},
    {"sec-fetch-site", "none"},
    {"sec-fetch-mode", "navigate"},
    {"sec-fetch-user", "?1"},
    {"sec-fetch-dest", "document"},
    {"accept-encoding", "gzip, deflate, br, zstd"},
    {"accept-language", "en-US,en;q=0.9"},
    {"priority", "u=0, i"}
  ]

  test "attach/2 without a profile still drops Req's default user-agent" do
    raw = capture_request(&CloakedReq.attach/1)

    refute raw =~ ~r/req\/\d+\.\d+\.\d+/
  end

  test "an explicit :user_agent option wins over the profile" do
    raw = capture_request(&CloakedReq.impersonate(&1, :chrome_136), user_agent: "my-crawler/1.0")

    assert header(raw, "user-agent") == "my-crawler/1.0"
  end

  test "an explicit user-agent header wins over the profile" do
    raw = capture_request(&CloakedReq.impersonate(&1, :chrome_136), headers: [{"user-agent", "my-crawler/2.0"}])

    assert header(raw, "user-agent") == "my-crawler/2.0"
  end

  test "a Latin-1 header value goes out as its raw bytes" do
    raw = capture_request(&CloakedReq.attach/1, headers: [{"x-name", <<"M", 0xFC, "ller">>}])

    assert raw =~ <<"x-name: M", 0xFC, "ller\r\n">>
  end

  describe "default_headers: false" do
    # A fetch()-shaped set: no navigation-only sec-fetch-user or
    # upgrade-insecure-requests, which a profile's defaults would add.
    @fetch_headers [
      {"sec-ch-ua", ~s("Chromium";v="136", "Google Chrome";v="136", "Not.A/Brand";v="99")},
      {"user-agent", "Mozilla/5.0 Chrome/136.0.0.0"},
      {"accept", "*/*"},
      {"sec-fetch-site", "same-origin"},
      {"sec-fetch-mode", "cors"},
      {"sec-fetch-dest", "empty"},
      {"accept-encoding", "gzip, deflate, br, zstd"},
      {"accept-language", "en-US,en;q=0.9"}
    ]
    @fetch_order Enum.map(@fetch_headers, &elem(&1, 0))

    test "sends exactly the request headers, in header_order" do
      raw =
        capture_request(
          &CloakedReq.attach(&1,
            impersonate: :chrome_136,
            default_headers: false,
            header_order: @fetch_order
          ),
          headers: @fetch_headers
        )

      assert wire_headers(raw) == @fetch_headers
    end

    test "applies to a request through a pool" do
      {:ok, pool} = Pool.new(impersonate: :chrome_136)

      raw =
        capture_request(
          &CloakedReq.attach(&1,
            pool: pool,
            default_headers: false,
            header_order: @fetch_order
          ),
          headers: @fetch_headers
        )

      assert wire_headers(raw) == @fetch_headers
    end
  end

  # wreq decodes the body itself, so it asks for the encodings it can decode
  # when the request does not. Send accept-encoding to own its value and place.
  test "default_headers: false still gets wreq's accept-encoding when the request has none" do
    raw =
      capture_request(&CloakedReq.attach(&1, impersonate: :chrome_136, default_headers: false),
        headers: [{"x-a", "1"}]
      )

    assert [{"x-a", "1"}, {"accept-encoding", _}] = wire_headers(raw)
  end

  describe "header_order" do
    test "orders the profile's default headers too" do
      order = ["accept-language", "user-agent"]
      raw = capture_request(&CloakedReq.attach(&1, impersonate: :chrome_136, header_order: order))

      assert raw |> wire_headers() |> Enum.take(2) |> Enum.map(&elem(&1, 0)) == order
      assert length(wire_headers(raw)) == length(@chrome_136_headers)
    end

    test "names are case-insensitive" do
      raw =
        capture_request(
          &CloakedReq.attach(&1,
            impersonate: :chrome_136,
            default_headers: false,
            header_order: ["X-B", "X-A"]
          ),
          headers: [{"x-a", "1"}, {"x-b", "2"}, {"accept-encoding", "gzip"}]
        )

      assert wire_headers(raw) == [{"x-b", "2"}, {"x-a", "1"}, {"accept-encoding", "gzip"}]
    end
  end

  test "invalid default_headers and header_order are rejected" do
    req = Req.new(url: "http://127.0.0.1:1", retry: false)

    assert {:error, %CloakedReq.AdapterError{error: %{message: "default_headers must be a boolean"}}} =
             req |> CloakedReq.attach(default_headers: :no) |> Req.request()

    assert {:error, %CloakedReq.AdapterError{error: %{message: "header_order must be a list of header name strings"}}} =
             req |> CloakedReq.attach(header_order: [:accept]) |> Req.request()
  end

  test "a compressed response still decodes with the profile accept-encoding" do
    body = String.duplicate("cloaked-req-", 500)
    headers = [{"content-type", "text/plain"}, {"content-encoding", "gzip"}]
    response = TestServer.build_response(200, headers, :zlib.gzip(body))
    {url, _server} = TestServer.start(response: response)

    req = [url: url, retry: false] |> Req.new() |> CloakedReq.impersonate(:chrome_136)

    assert {:ok, %Req.Response{status: 200} = resp} = Req.request(req)
    assert resp.body == body
  end

  test "chrome_136 emits its full header set in order" do
    raw = capture_request(&CloakedReq.impersonate(&1, :chrome_136))

    emitted = raw |> headers() |> Enum.reject(&(elem(&1, 0) == "host"))

    assert emitted == @chrome_136_headers
  end

  @spec capture_request((Req.Request.t() -> Req.Request.t()), keyword()) :: binary()
  defp capture_request(attach, options \\ []) do
    response = TestServer.build_response(200, [{"content-type", "text/plain"}], "ok")
    {url, server} = TestServer.start(response: response)

    req = [url: url, retry: false] |> Keyword.merge(options) |> Req.new() |> attach.()

    assert {:ok, %Req.Response{status: 200}} = Req.request(req)
    TestServer.get_request(server)
  end

  # Headers as they reached the wire, minus `host` (its value carries the
  # ephemeral port).
  defp wire_headers(raw), do: raw |> headers() |> Enum.reject(&match?({"host", _}, &1))

  @spec headers(binary()) :: [{String.t(), String.t()}]
  defp headers(raw) do
    [head | _body] = String.split(raw, "\r\n\r\n", parts: 2)

    head
    |> String.split("\r\n")
    |> Enum.drop(1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(fn line ->
      [name, value] = String.split(line, ": ", parts: 2)
      {String.downcase(name), value}
    end)
  end

  @spec header(binary(), String.t()) :: String.t()
  defp header(raw, name) do
    raw |> headers() |> List.keyfind(name, 0) |> then(fn {_name, value} -> value end)
  end
end
