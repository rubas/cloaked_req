defmodule CloakedReq.ExternalFingerprintTest do
  @moduledoc """
  Verifies that CloakedReq impersonation produces a different TLS fingerprint
  than plain Req, and that the fingerprint contains expected JA4 data.
  """

  use ExUnit.Case, async: false

  @moduletag :external

  @fingerprint_url "https://thumbprint.me/api/v1/probe"

  test "impersonated request has a different JA4 fingerprint than plain Req" do
    plain_fingerprint =
      [url: @fingerprint_url]
      |> Req.new()
      |> fetch_fingerprint()

    impersonated_fingerprint =
      [url: @fingerprint_url]
      |> Req.new()
      |> CloakedReq.attach(impersonate: :chrome_136)
      |> fetch_fingerprint()

    assert plain_fingerprint, "plain Req must return a JA4 fingerprint"
    assert impersonated_fingerprint, "impersonated request must return a JA4 fingerprint"
    assert plain_fingerprint != impersonated_fingerprint
  end

  test "impersonated request returns JA4 fingerprints" do
    response =
      [url: @fingerprint_url]
      |> Req.new()
      |> CloakedReq.attach(impersonate: :chrome_136)
      |> Req.get!()

    assert response.status in 200..299
    payload = decode_body(response)
    assert is_binary(payload["ja4"]) and payload["ja4"] != ""
    assert is_binary(payload["ja4_r"]) and payload["ja4_r"] != ""
  end

  test "a pool's fingerprint overrides a conflicting per-request impersonate" do
    {:ok, chrome_pool} = CloakedReq.Pool.new(impersonate: :chrome_136)

    via_pool =
      [url: @fingerprint_url]
      |> Req.new()
      |> CloakedReq.attach(pool: chrome_pool)
      |> fetch_fingerprint()

    via_pool_with_conflict =
      [url: @fingerprint_url]
      |> Req.new()
      |> CloakedReq.attach(pool: chrome_pool, impersonate: :firefox_136)
      |> fetch_fingerprint()

    firefox_direct =
      [url: @fingerprint_url]
      |> Req.new()
      |> CloakedReq.attach(impersonate: :firefox_136)
      |> fetch_fingerprint()

    assert via_pool, "pooled request must return a JA4 fingerprint"

    assert via_pool_with_conflict == via_pool,
           "the pool's fingerprint must win over a per-request impersonate"

    assert via_pool_with_conflict != firefox_direct,
           "the per-request firefox profile must not leak through a chrome pool"
  end

  @spec fetch_fingerprint(Req.Request.t()) :: String.t() | nil
  defp fetch_fingerprint(request) do
    response = Req.get!(request)

    case decode_body(response) do
      %{"ja4" => ja4} -> ja4
      _ -> nil
    end
  end

  @spec decode_body(Req.Response.t()) :: map()
  defp decode_body(%Req.Response{body: body}) when is_map(body), do: body

  defp decode_body(%Req.Response{body: body}) when is_binary(body) do
    case JSON.decode(body) do
      {:ok, payload} when is_map(payload) -> payload
      _ -> %{}
    end
  end
end
