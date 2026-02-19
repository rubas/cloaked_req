defmodule CloakedReq.Native do
  @moduledoc """
  Rust NIF interface for HTTP request execution via `wreq`.

  Request and response metadata are passed as native Elixir maps encoded/decoded
  directly by Rustler's NifMap. Bodies are passed as raw BEAM binaries.
  """

  use RustlerPrecompiled,
    otp_app: :cloaked_req,
    crate: "cloaked_req_native",
    base_url: "https://github.com/rubas/cloaked_req/releases/download/v#{Mix.Project.config()[:version]}",
    version: Mix.Project.config()[:version],
    force_build: System.get_env("CLOAKED_REQ_BUILD") in ["1", "true"],
    targets: ~w(
      aarch64-apple-darwin
      aarch64-unknown-linux-gnu
      x86_64-unknown-linux-gnu
    )

  alias CloakedReq.Error

  @doc """
  Creates a new Rust-side cookie jar resource.

  Returns an opaque reference managed by the BEAM garbage collector.
  """
  @spec create_cookie_jar() :: reference()
  def create_cookie_jar do
    nif_create_cookie_jar()
  end

  @doc """
  Sends the request metadata and body to the Rust NIF.

  The metadata map is passed directly to the NIF (decoded via Rustler's NifMap).
  The body is passed as a raw binary (or nil). An optional cookie jar reference
  enables automatic cookie persistence across requests.
  Returns `{:ok, response_meta, body}` or `{:error, %CloakedReq.Error{}}`.
  """
  @spec perform_request(map(), binary() | nil, reference() | nil) :: {:ok, map(), binary()} | {:error, Error.t()}
  def perform_request(payload, body, cookie_jar_ref \\ nil)

  def perform_request(payload, body, cookie_jar_ref) when is_map(payload) do
    case safe_nif_perform_request(payload, body, cookie_jar_ref) do
      {:ok, meta, response_body} when is_map(meta) and is_binary(response_body) ->
        {:ok, meta, response_body}

      {:error, %{"type" => type, "message" => message, "details" => details}}
      when is_binary(type) and is_binary(message) ->
        {:error, Error.new(to_error_type(type), message, details)}

      other ->
        {:error, Error.new(:native_error, "unexpected native response", %{response: inspect(other)})}
    end
  end

  def perform_request(_payload, _body, _cookie_jar_ref) do
    {:error, Error.new(:invalid_request, "native payload must be a map")}
  end

  defp safe_nif_perform_request(payload, body, cookie_jar_ref) do
    nif_perform_request(payload, body, cookie_jar_ref)
  rescue
    error in [ErlangError] ->
      {:error, %{"type" => "nif_panic", "message" => Exception.message(error), "details" => %{}}}
  end

  @spec to_error_type(String.t()) :: atom()
  defp to_error_type("nif_panic"), do: :nif_panic
  defp to_error_type("decode_request"), do: :decode_request
  defp to_error_type("invalid_request"), do: :invalid_request
  defp to_error_type("transport_error"), do: :transport_error
  defp to_error_type("runtime_error"), do: :runtime_error
  defp to_error_type("invalid_native_response"), do: :invalid_native_response
  defp to_error_type(_), do: :native_error

  defp nif_create_cookie_jar, do: :erlang.nif_error(:nif_not_loaded)
  defp nif_perform_request(_payload, _body, _cookie_jar_ref), do: :erlang.nif_error(:nif_not_loaded)
end
