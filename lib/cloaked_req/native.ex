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
    nif_versions: ["2.17"],
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
  Builds a Rust-side HTTP client with its own connection pool.

  The config map is passed directly to the NIF (decoded via Rustler's NifMap).
  Returns `{:ok, reference()}` for the pooled client (managed by the BEAM
  garbage collector) or `{:error, %CloakedReq.Error{}}`.
  """
  @spec new_pool(map()) :: {:ok, reference()} | {:error, Error.t()}
  def new_pool(config) when is_map(config) do
    case nif_new_pool(config) do
      {:ok, ref} -> {:ok, ref}
      {:error, native_error} -> {:error, to_error(native_error)}
    end
  end

  @doc """
  Sends the request metadata and body to the Rust NIF and waits for the reply.

  The metadata map is passed directly to the NIF (decoded via Rustler's NifMap).
  The body is passed as a raw binary (or nil). An optional cookie jar reference
  enables automatic cookie persistence across requests, and an optional pool
  reference routes the request through a dedicated client built with
  `new_pool/1`.
  Returns `{:ok, response_meta, body}` or `{:error, %CloakedReq.Error{}}`.

  The wait has no timeout of its own: the native task replies on every path,
  a panic included, and `:receive_timeout_ms` bounds each wait for the server
  there.
  """
  @spec perform_request(map(), binary() | nil, reference() | nil, reference() | nil) ::
          {:ok, map(), binary()} | {:error, Error.t()}
  def perform_request(payload, body, cookie_jar_ref, pool_ref) do
    token = make_ref()

    case safe_nif_perform_request(payload, body, token, cookie_jar_ref, pool_ref) do
      :ok ->
        receive do
          {:cloaked_req_response, ^token, {:ok, _meta, _body} = result} -> result
          {:cloaked_req_response, ^token, {:error, native_error}} -> {:error, to_error(native_error)}
        end

      {:error, _error} = error ->
        error
    end
  end

  defp safe_nif_perform_request(payload, body, token, cookie_jar_ref, pool_ref) do
    nif_perform_request(payload, body, token, cookie_jar_ref, pool_ref)
  rescue
    error in [ErlangError] -> {:error, Error.new(:nif_panic, Exception.message(error))}
  end

  @spec to_error(map()) :: Error.t()
  defp to_error(%{"type" => type, "message" => message, "details" => details}) do
    type |> to_error_type() |> Error.new(message, details)
  end

  @spec to_error_type(String.t()) :: Error.type()
  defp to_error_type("invalid_request"), do: :invalid_request
  defp to_error_type("transport_error"), do: :transport_error
  defp to_error_type("nif_panic"), do: :nif_panic

  defp nif_create_cookie_jar, do: :erlang.nif_error(:nif_not_loaded)
  defp nif_new_pool(_config), do: :erlang.nif_error(:nif_not_loaded)

  defp nif_perform_request(_payload, _body, _token, _cookie_jar_ref, _pool_ref), do: :erlang.nif_error(:nif_not_loaded)
end
