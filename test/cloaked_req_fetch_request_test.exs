defmodule CloakedReq.FetchRequestTest do
  @moduledoc """
  Verifies that a `fetch()`-shaped request through a navigation profile goes
  out without the navigation-only headers, and that it keeps the profile's
  TLS and HTTP/2 fingerprint.
  """

  use ExUnit.Case, async: true

  alias CloakedReq.FingerprintServer
  alias CloakedReq.Pool

  # What Chrome sends for a same-origin `fetch()`, in its order.
  @fetch_headers [
    {"sec-ch-ua-platform", ~s("macOS")},
    {"user-agent",
     "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36"},
    {"sec-ch-ua", ~s["Google Chrome";v="149", "Chromium";v="149", "Not)A;Brand";v="24"]},
    {"sec-ch-ua-mobile", "?0"},
    {"accept", "*/*"},
    {"sec-fetch-site", "same-origin"},
    {"sec-fetch-mode", "cors"},
    {"sec-fetch-dest", "empty"},
    {"referer", "https://example.com/"},
    {"accept-encoding", "gzip, deflate, br, zstd"},
    {"accept-language", "en-US,en;q=0.9"},
    {"priority", "u=1, i"}
  ]
  @fetch_options [default_headers: false, header_order: Enum.map(@fetch_headers, &elem(&1, 0))]

  test "a navigation through :chrome_149 carries sec-fetch-user and upgrade-insecure-requests" do
    url = FingerprintServer.start_h2()

    navigation = h2_request(url, new_pool(), [], [])

    assert {"sec-fetch-user", "?1"} in navigation.headers
    assert {"upgrade-insecure-requests", "1"} in navigation.headers
  end

  test "a fetch() request through :chrome_149 sends exactly its own headers, in header_order" do
    url = FingerprintServer.start_h2()

    fetch = h2_request(url, new_pool(), @fetch_headers, @fetch_options)

    assert Enum.reject(fetch.headers, &pseudo?/1) == @fetch_headers
  end

  test "without default_headers: false the fetch() request still carries the navigation-only pair" do
    url = FingerprintServer.start_h2()

    fetch = h2_request(url, new_pool(), @fetch_headers, [])

    assert {"sec-fetch-user", "?1"} in fetch.headers
    assert {"upgrade-insecure-requests", "1"} in fetch.headers
  end

  test "a navigation and a fetch() request share one connection of a pool" do
    url = FingerprintServer.start_h2()
    pool = new_pool()

    navigation = h2_request(url, pool, [], [])
    fetch = h2_request(url, pool, @fetch_headers, @fetch_options)

    assert fetch.connection == navigation.connection
    refute List.keymember?(fetch.headers, "sec-fetch-user", 0)
    assert List.keymember?(navigation.headers, "sec-fetch-user", 0)
  end

  test "default_headers: false keeps the HTTP/2 fingerprint of :chrome_149" do
    url = FingerprintServer.start_h2()

    navigation = h2_request(url, new_pool(), [], [])
    fetch = h2_request(url, new_pool(), @fetch_headers, @fetch_options)

    assert fetch.connection != navigation.connection
    assert h2_fingerprint(fetch) == h2_fingerprint(navigation)

    # Chrome's SETTINGS: header table size, no push, initial window size, max header list size.
    assert [{1, 65_536}, {2, 0}, {4, 6_291_456}, {6, 262_144}] = navigation.settings
    assert navigation.window_update == 15_663_105
    assert h2_fingerprint(navigation).pseudo_headers == [":method", ":authority", ":scheme", ":path"]
  end

  test "default_headers: false keeps the TLS ClientHello of :chrome_149" do
    navigation = FingerprintServer.client_hello(&send_tls_request(&1, [], []))
    fetch = FingerprintServer.client_hello(&send_tls_request(&1, @fetch_headers, @fetch_options))

    assert fetch == navigation
    assert navigation.alpn == ["h2", "http/1.1"]
    # TLS 1.3, and the X25519MLKEM768 key share that current Chrome sends.
    assert 0x0304 in navigation.versions
    assert 0x11EC in navigation.key_shares
  end

  defp new_pool do
    {:ok, pool} = Pool.new(impersonate: :chrome_149, insecure_skip_verify: true)
    pool
  end

  defp h2_request(url, pool, headers, options) do
    request = [url: url, retry: false, headers: headers] |> Req.new() |> CloakedReq.attach([pool: pool] ++ options)

    assert {:ok, %Req.Response{status: 200}} = Req.request(request)
    FingerprintServer.next_h2_request()
  end

  # The server closes after the ClientHello, so the request fails.
  defp send_tls_request(url, headers, options) do
    request =
      [url: url, retry: false, headers: headers]
      |> Req.new()
      |> CloakedReq.attach([impersonate: :chrome_149, insecure_skip_verify: true] ++ options)

    assert {:error, _transport_error} = Req.request(request)
  end

  defp h2_fingerprint(request) do
    %{
      settings: request.settings,
      window_update: request.window_update,
      priority: request.priority,
      pseudo_headers: request.headers |> Enum.filter(&pseudo?/1) |> Enum.map(&elem(&1, 0))
    }
  end

  defp pseudo?({name, _value}), do: String.starts_with?(name, ":")
end
