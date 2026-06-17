defmodule CloakedReq.PoolTest do
  # Covers CloakedReq.Pool: build (new/1, new!/1), option validation, and the
  # pool request path through the full Elixir -> NIF -> Rust wreq pipeline.
  # Assumes the real NIF is loaded (CLOAKED_REQ_BUILD) so pool refs are live
  # client resources, and that TestServer serves one canned response per start.

  use ExUnit.Case, async: true

  alias CloakedReq.AdapterError
  alias CloakedReq.Error
  alias CloakedReq.Pool
  alias CloakedReq.TestServer

  doctest Pool, import: false

  # -------------------------------------------------------------------
  # Build
  # -------------------------------------------------------------------

  test "new/1 returns a Pool struct with an opaque ref for a valid profile" do
    assert {:ok, %Pool{ref: ref}} = Pool.new(impersonate: :chrome_136)
    assert is_reference(ref)
  end

  test "new/1 with no options returns a Pool struct" do
    assert {:ok, %Pool{ref: ref}} = Pool.new([])
    assert is_reference(ref)
  end

  test "new/1 accepts all options" do
    assert {:ok, %Pool{ref: ref}} =
             Pool.new(
               impersonate: :chrome_136,
               insecure_skip_verify: true,
               connect_timeout: 5_000,
               pool_idle_timeout: 10_000
             )

    assert is_reference(ref)
  end

  test "new!/1 returns the struct directly" do
    assert %Pool{ref: ref} = Pool.new!(impersonate: :chrome_136)
    assert is_reference(ref)
  end

  test "two pools have different references" do
    {:ok, pool1} = Pool.new(impersonate: :chrome_136)
    {:ok, pool2} = Pool.new(impersonate: :chrome_136)
    refute pool1.ref == pool2.ref
  end

  # -------------------------------------------------------------------
  # Build errors
  # -------------------------------------------------------------------

  test "new/1 with an unknown profile returns an error" do
    assert {:error, %Error{type: :invalid_request}} = Pool.new(impersonate: :not_a_browser)
  end

  test "new!/1 with an unknown profile raises ArgumentError" do
    assert_raise ArgumentError, fn -> Pool.new!(impersonate: :not_a_browser) end
  end

  # -------------------------------------------------------------------
  # Option validation
  # -------------------------------------------------------------------

  test "non-atom impersonate is rejected" do
    assert {:error, %Error{type: :invalid_request}} = Pool.new(impersonate: "chrome_136")
  end

  test "non-boolean insecure_skip_verify is rejected" do
    assert {:error, %Error{type: :invalid_request}} = Pool.new(insecure_skip_verify: "yes")
  end

  test "non-positive connect_timeout is rejected" do
    assert {:error, %Error{type: :invalid_request}} = Pool.new(connect_timeout: 0)
  end

  test "bad pool_idle_timeout is rejected" do
    assert {:error, %Error{type: :invalid_request}} = Pool.new(pool_idle_timeout: -1)
  end

  # -------------------------------------------------------------------
  # Pool request path (e2e)
  # -------------------------------------------------------------------

  test "a request routed through a pool reaches the server and returns 200" do
    {:ok, pool} = Pool.new(impersonate: :chrome_136)

    response = TestServer.build_response(200, [{"content-type", "text/plain"}], "pooled")
    {url, server} = TestServer.start(response: response)

    req = [url: url, retry: false] |> Req.new() |> CloakedReq.attach(pool: pool)

    assert {:ok, %Req.Response{status: 200, body: "pooled"}} = Req.request(req)

    raw = TestServer.get_request(server)
    assert raw =~ ~r/^GET \/ HTTP\/1\.1/
  end

  test "attach/2 with a non-pool value yields an adapter error" do
    {url, _server} =
      TestServer.start(response: TestServer.build_response(200, [], "ok"))

    req = [url: url, retry: false] |> Req.new() |> CloakedReq.attach(pool: "nope")

    assert {:error, %AdapterError{} = error} = Req.request(req)
    assert error.error.type == :invalid_request
  end

  test "a pool ignores conflicting per-request impersonate and insecure_skip_verify" do
    {:ok, pool} = Pool.new(impersonate: :chrome_136)

    response = TestServer.build_response(200, [{"content-type", "text/plain"}], "pooled")
    {url, _server} = TestServer.start(response: response)

    # The pool's client governs the fingerprint and TLS verification; the
    # conflicting per-request options are validated but must not change which
    # client runs the request, so the request still succeeds through the pool.
    req =
      [url: url, retry: false]
      |> Req.new()
      |> CloakedReq.attach(pool: pool, impersonate: :firefox_136, insecure_skip_verify: true)

    assert {:ok, %Req.Response{status: 200, body: "pooled"}} = Req.request(req)
  end

  test "a pool composes with a cookie jar across requests" do
    jar = CloakedReq.CookieJar.new()
    {:ok, pool} = Pool.new(impersonate: :chrome_136)

    set = TestServer.build_response(200, [{"set-cookie", "sid=abc; Path=/"}], "ok")
    {set_url, _set_server} = TestServer.start(response: set)

    assert {:ok, %Req.Response{status: 200}} =
             [url: set_url, retry: false]
             |> Req.new()
             |> CloakedReq.attach(pool: pool, cookie_jar: jar)
             |> Req.request()

    echo = TestServer.build_response(200, [], "ok")
    {echo_url, echo_server} = TestServer.start(response: echo)

    assert {:ok, %Req.Response{status: 200}} =
             [url: echo_url, retry: false]
             |> Req.new()
             |> CloakedReq.attach(pool: pool, cookie_jar: jar)
             |> Req.request()

    raw = TestServer.get_request(echo_server)
    assert raw =~ ~r/cookie:.*sid=abc/i
  end
end
