defmodule CloakedReq.ExternalFingerprintTest do
  @moduledoc """
  Verifies that CloakedReq impersonation produces a different TLS fingerprint
  than plain Req, and that the fingerprint contains expected JA4 data.
  """

  use ExUnit.Case, async: false

  @moduletag :external

  @fingerprint_url "https://tls.peet.ws/api/all"

  test "impersonated request has a different JA4 fingerprint than plain Req" do
    plain_fingerprint =
      [url: @fingerprint_url, connect_options: [transport_opts: [verify: :verify_none]]]
      |> Req.new()
      |> fetch_fingerprint()

    impersonated_fingerprint =
      [url: @fingerprint_url]
      |> Req.new()
      |> CloakedReq.attach(impersonate: :chrome_136, insecure_skip_verify: true)
      |> fetch_fingerprint()

    assert plain_fingerprint, "plain Req must return a JA4 fingerprint"
    assert impersonated_fingerprint, "impersonated request must return a JA4 fingerprint"
    assert plain_fingerprint != impersonated_fingerprint
  end

  test "impersonated request returns fingerprint payload with JA4 and user agent" do
    response =
      [url: @fingerprint_url]
      |> Req.new()
      |> CloakedReq.attach(impersonate: :chrome_136, insecure_skip_verify: true)
      |> Req.get!()

    assert response.status in 200..299
    payload = decode_body(response)
    assert Enum.any?(Map.keys(payload), &String.starts_with?(&1, "ja4"))
    assert is_binary(payload["user_agent"])
    assert payload["user_agent"] != ""
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
