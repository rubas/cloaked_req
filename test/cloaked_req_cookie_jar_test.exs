defmodule CloakedReq.CookieJarTest do
  @moduledoc """
  Verifies cookie jar lifecycle, persistence, isolation, and PSL-based domain validation
  through the full Elixir -> NIF -> Rust wreq pipeline.
  """

  use ExUnit.Case, async: true

  alias CloakedReq.CookieJar
  alias CloakedReq.TestServer

  doctest CookieJar, import: false

  # -------------------------------------------------------------------
  # Lifecycle
  # -------------------------------------------------------------------

  test "new/0 returns a CookieJar struct with an opaque ref" do
    jar = CookieJar.new()
    assert %CookieJar{} = jar
    assert is_reference(jar.ref)
  end

  test "two jars have different references" do
    jar1 = CookieJar.new()
    jar2 = CookieJar.new()
    refute jar1.ref == jar2.ref
  end

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

  # -------------------------------------------------------------------
  # PSL rejection
  # -------------------------------------------------------------------

  test "cookie with Domain=com is rejected by PSL validation" do
    jar = CookieJar.new()

    # Server tries to set a cookie for the public suffix "com"
    set_response = TestServer.build_response(200, [{"set-cookie", "evil=1; Domain=com; Path=/"}], "ok")
    {set_url, _set_server} = TestServer.start(response: set_response)
    req = [url: set_url, retry: false] |> Req.new() |> CloakedReq.attach(cookie_jar: jar)
    assert {:ok, _} = Req.request(req)

    # Verify cookie was NOT stored
    verify_response = TestServer.build_response(200, [], "ok")
    {verify_url, verify_server} = TestServer.start(response: verify_response)
    req = [url: verify_url, retry: false] |> Req.new() |> CloakedReq.attach(cookie_jar: jar)
    assert {:ok, _} = Req.request(req)

    raw = TestServer.get_request(verify_server)
    refute raw =~ "evil=1"
  end

  # -------------------------------------------------------------------
  # Redirect with cookies
  # -------------------------------------------------------------------

  test "cookies set during redirect are available for subsequent requests" do
    jar = CookieJar.new()

    # Destination server returns 200
    dest_response = TestServer.build_response(200, [{"content-type", "text/plain"}], "arrived")
    {dest_url, _dest_server} = TestServer.start(response: dest_response)

    # Origin server redirects with a set-cookie header
    redirect_response =
      TestServer.build_response(
        302,
        [{"location", dest_url}, {"set-cookie", "redirect_token=abc; Path=/"}],
        ""
      )

    {origin_url, _origin_server} = TestServer.start(response: redirect_response)

    req = [url: origin_url, retry: false] |> Req.new() |> CloakedReq.attach(cookie_jar: jar)
    assert {:ok, %Req.Response{status: 200}} = Req.request(req)

    # Verify cookie from redirect is present in a subsequent request
    verify_response = TestServer.build_response(200, [], "ok")
    {verify_url, verify_server} = TestServer.start(response: verify_response)
    req = [url: verify_url, retry: false] |> Req.new() |> CloakedReq.attach(cookie_jar: jar)
    assert {:ok, _} = Req.request(req)

    raw = TestServer.get_request(verify_server)
    assert raw =~ "redirect_token=abc"
  end
end
