defmodule CloakedReq.CookieJarTest do
  @moduledoc """
  Verifies cookie jar persistence, isolation, header precedence, domain validation, and
  redirects through the full Elixir -> NIF -> Rust wreq pipeline.
  """

  use ExUnit.Case, async: true

  alias CloakedReq.CookieJar
  alias CloakedReq.TestServer

  doctest CookieJar, import: false

  # -------------------------------------------------------------------
  # Cookie persistence (e2e)
  # -------------------------------------------------------------------

  test "cookies set by server are sent in subsequent requests" do
    jar = CookieJar.new()

    # First server sets a cookie
    set_response =
      TestServer.build_response(200, [{"set-cookie", "session=abc123; Path=/"}], "logged in")

    {set_url, _set_server} = TestServer.start(response: set_response)

    req = [url: set_url, retry: false] |> Req.new() |> CloakedReq.attach(cookie_jar: jar)
    assert {:ok, %Req.Response{status: 200}} = Req.request(req)

    # Second server captures request to verify cookie is present
    verify_response = TestServer.build_response(200, [{"content-type", "text/plain"}], "ok")
    {verify_url, verify_server} = TestServer.start(response: verify_response)

    req = [url: verify_url, retry: false] |> Req.new() |> CloakedReq.attach(cookie_jar: jar)
    assert {:ok, %Req.Response{status: 200}} = Req.request(req)

    raw = TestServer.get_request(verify_server)
    assert raw =~ ~r/cookie:.*session=abc123/i
  end

  test "multiple cookies are sent in subsequent requests" do
    jar = CookieJar.new()

    set_response =
      TestServer.build_response(
        200,
        [
          {"set-cookie", "a=1; Path=/"},
          {"set-cookie", "b=2; Path=/"}
        ],
        "ok"
      )

    {set_url, _set_server} = TestServer.start(response: set_response)
    req = [url: set_url, retry: false] |> Req.new() |> CloakedReq.attach(cookie_jar: jar)
    assert {:ok, _} = Req.request(req)

    verify_response = TestServer.build_response(200, [], "ok")
    {verify_url, verify_server} = TestServer.start(response: verify_response)
    req = [url: verify_url, retry: false] |> Req.new() |> CloakedReq.attach(cookie_jar: jar)
    assert {:ok, _} = Req.request(req)

    raw = TestServer.get_request(verify_server)
    assert raw =~ "a=1"
    assert raw =~ "b=2"
  end

  # -------------------------------------------------------------------
  # Cookie isolation
  # -------------------------------------------------------------------

  test "separate jars do not share cookies" do
    jar1 = CookieJar.new()
    jar2 = CookieJar.new()

    # Set cookie in jar1
    set_response = TestServer.build_response(200, [{"set-cookie", "token=secret; Path=/"}], "ok")
    {set_url, _set_server} = TestServer.start(response: set_response)
    req = [url: set_url, retry: false] |> Req.new() |> CloakedReq.attach(cookie_jar: jar1)
    assert {:ok, _} = Req.request(req)

    # Verify jar2 does NOT send the cookie
    verify_response = TestServer.build_response(200, [], "ok")
    {verify_url, verify_server} = TestServer.start(response: verify_response)
    req = [url: verify_url, retry: false] |> Req.new() |> CloakedReq.attach(cookie_jar: jar2)
    assert {:ok, _} = Req.request(req)

    raw = TestServer.get_request(verify_server)
    refute raw =~ "token=secret"
  end

  test "request without cookie_jar does not receive cookies from jar" do
    jar = CookieJar.new()

    # Set cookie in jar
    set_response = TestServer.build_response(200, [{"set-cookie", "sid=xyz; Path=/"}], "ok")
    {set_url, _set_server} = TestServer.start(response: set_response)
    req = [url: set_url, retry: false] |> Req.new() |> CloakedReq.attach(cookie_jar: jar)
    assert {:ok, _} = Req.request(req)

    # Request without jar should not send cookie
    verify_response = TestServer.build_response(200, [], "ok")
    {verify_url, verify_server} = TestServer.start(response: verify_response)
    req = [url: verify_url, retry: false] |> Req.new() |> CloakedReq.attach()
    assert {:ok, _} = Req.request(req)

    raw = TestServer.get_request(verify_server)
    refute raw =~ "sid=xyz"
  end

  test "an explicit cookie header wins over the jar and goes on the wire once" do
    jar = CookieJar.new()

    set_response = TestServer.build_response(200, [{"set-cookie", "session=abc123; Path=/"}], "ok")
    {set_url, _set_server} = TestServer.start(response: set_response)
    req = [url: set_url, retry: false] |> Req.new() |> CloakedReq.attach(cookie_jar: jar)
    assert {:ok, %Req.Response{status: 200}} = Req.request(req)

    verify_response = TestServer.build_response(200, [], "ok")
    {verify_url, verify_server} = TestServer.start(response: verify_response)

    req =
      [url: verify_url, retry: false, headers: [cookie: "explicit=1"]]
      |> Req.new()
      |> CloakedReq.attach(cookie_jar: jar)

    assert {:ok, %Req.Response{status: 200}} = Req.request(req)

    raw = TestServer.get_request(verify_server)
    assert Regex.scan(~r/^cookie: (.*)\r$/im, raw) == [["cookie: explicit=1\r", "explicit=1"]]
  end

  # -------------------------------------------------------------------
  # Domain rejection
  # -------------------------------------------------------------------

  test "cookie with a Domain that does not match the host is not stored" do
    jar = CookieJar.new()

    set_response = TestServer.build_response(200, [{"set-cookie", "x=1; Domain=example.com; Path=/"}], "ok")
    {set_url, _set_server} = TestServer.start(response: set_response)
    req = [url: set_url, retry: false] |> Req.new() |> CloakedReq.attach(cookie_jar: jar)
    assert {:ok, _} = Req.request(req)

    verify_response = TestServer.build_response(200, [], "ok")
    {verify_url, verify_server} = TestServer.start(response: verify_response)
    req = [url: verify_url, retry: false] |> Req.new() |> CloakedReq.attach(cookie_jar: jar)
    assert {:ok, _} = Req.request(req)

    raw = TestServer.get_request(verify_server)
    refute raw =~ "x=1"
  end

  test "cookie with a Domain equal to the IP host is stored" do
    jar = CookieJar.new()

    set_response = TestServer.build_response(200, [{"set-cookie", "x=1; Domain=127.0.0.1; Path=/"}], "ok")
    {set_url, _set_server} = TestServer.start(response: set_response)
    req = [url: set_url, retry: false] |> Req.new() |> CloakedReq.attach(cookie_jar: jar)
    assert {:ok, _} = Req.request(req)

    verify_response = TestServer.build_response(200, [], "ok")
    {verify_url, verify_server} = TestServer.start(response: verify_response)
    req = [url: verify_url, retry: false] |> Req.new() |> CloakedReq.attach(cookie_jar: jar)
    assert {:ok, _} = Req.request(req)

    raw = TestServer.get_request(verify_server)
    assert raw =~ "x=1"
  end

  test "cookie with Domain=com is rejected by PSL validation" do
    jar = CookieJar.new()

    # Both requests go through a TestServer proxy, so the request host is www.a.com.
    # The jar's own domain match accepts Domain=com for that host; only the PSL check rejects it.
    set_response = TestServer.build_response(200, [{"set-cookie", "evil=1; Domain=com; Path=/"}], "ok")
    {set_proxy, _set_server} = TestServer.start(response: set_response)
    %URI{host: host, port: port} = URI.parse(set_proxy)

    req =
      [url: "http://www.a.com/", retry: false, connect_options: [proxy: {:http, host, port, []}]]
      |> Req.new()
      |> CloakedReq.attach(cookie_jar: jar)

    assert {:ok, _} = Req.request(req)

    verify_response = TestServer.build_response(200, [], "ok")
    {verify_proxy, verify_server} = TestServer.start(response: verify_response)
    %URI{host: host, port: port} = URI.parse(verify_proxy)

    req =
      [url: "http://www.a.com/", retry: false, connect_options: [proxy: {:http, host, port, []}]]
      |> Req.new()
      |> CloakedReq.attach(cookie_jar: jar)

    assert {:ok, _} = Req.request(req)

    raw = TestServer.get_request(verify_server)
    refute raw =~ "evil=1"
  end

  test "cookie with a Domain equal to a public-suffix host such as localhost is kept" do
    jar = CookieJar.new()

    set_response = TestServer.build_response(200, [{"set-cookie", "sid=1; Domain=localhost; Path=/"}], "ok")
    {set_url, _set_server} = TestServer.start(response: set_response, host: "localhost")
    req = [url: set_url, retry: false] |> Req.new() |> CloakedReq.attach(cookie_jar: jar)
    assert {:ok, _} = Req.request(req)

    verify_response = TestServer.build_response(200, [], "ok")
    {verify_url, verify_server} = TestServer.start(response: verify_response, host: "localhost")
    req = [url: verify_url, retry: false] |> Req.new() |> CloakedReq.attach(cookie_jar: jar)
    assert {:ok, _} = Req.request(req)

    raw = TestServer.get_request(verify_server)
    assert raw =~ ~r/^cookie: sid=1\r$/im
  end

  # -------------------------------------------------------------------
  # Redirect with cookies
  # -------------------------------------------------------------------

  test "a cookie set on a redirect is sent to the redirect target" do
    jar = CookieJar.new()

    dest_response = TestServer.build_response(200, [{"content-type", "text/plain"}], "arrived")
    {dest_url, dest_server} = TestServer.start(response: dest_response)

    redirect_response =
      TestServer.build_response(
        302,
        [{"location", dest_url}, {"set-cookie", "redirect_token=abc; Path=/"}],
        ""
      )

    {origin_url, _origin_server} = TestServer.start(response: redirect_response)

    req = [url: origin_url, retry: false] |> Req.new() |> CloakedReq.attach(cookie_jar: jar)
    assert {:ok, %Req.Response{status: 200}} = Req.request(req)

    assert TestServer.get_request(dest_server) =~ "redirect_token=abc"
  end
end
