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
  Sends the request metadata and body to the Rust NIF.

  The metadata map is passed directly to the NIF (decoded via Rustler's NifMap).
  The body is passed as a raw binary (or nil). An optional cookie jar reference
  enables automatic cookie persistence across requests.
  Returns `{:ok, response_meta, body}` or `{:error, %CloakedReq.Error{}}`.
  """
  @spec perform_request(map(), binary() | nil, reference() | nil) :: {:ok, map(), binary()} | {:error, Error.t()}
  def perform_request(payload, body, cookie_jar_ref \\ nil)

  def perform_request(payload, body, cookie_jar_ref) when is_map(payload) do
    token = make_ref()

    case safe_nif_perform_request(payload, body, token, cookie_jar_ref) do
      :ok ->
        await_native_response(token, backstop_timeout(payload))

      other ->
        normalize_native_result(other)
    end
  end

  def perform_request(_payload, _body, _cookie_jar_ref) do
    {:error, Error.new(:invalid_request, "native payload must be a map")}
  end

  # Waits for the native task's token-tagged reply, with a timeout backstop.
  #
  # The NIF returns `:ok` immediately and the result arrives later as a message.
  # Caller liveness otherwise depends on the native side always sending that
  # message; the `after` clause bounds the wait so a native task that dies
  # without replying surfaces a `:transport_error` instead of hanging the caller
  # forever. A late reply is drained so it cannot land in a calling GenServer as
  # an unexpected `handle_info`. Public only so the backstop can be tested.
  @doc false
  @spec await_native_response(reference(), timeout()) :: {:ok, map(), binary()} | {:error, Error.t()}
  def await_native_response(token, timeout_ms) do
    receive do
      {:cloaked_req_response, ^token, result} -> normalize_native_result(result)
    after
      timeout_ms ->
        flush_native_response(token)

        {:error,
         Error.new(:transport_error, "native request produced no response within #{timeout_ms}ms", %{
           timeout_ms: timeout_ms
         })}
    end
  end

  @spec backstop_timeout(map()) :: pos_integer()
  defp backstop_timeout(payload) do
    Map.fetch!(payload, :receive_timeout_ms) + Map.fetch!(payload, :connect_timeout_ms) + 5_000
  end

  @spec flush_native_response(reference()) :: :ok
  defp flush_native_response(token) do
    receive do
      {:cloaked_req_response, ^token, _result} -> :ok
    after
      0 -> :ok
    end
  end

  @spec normalize_native_result(term()) :: {:ok, map(), binary()} | {:error, Error.t()}
  defp normalize_native_result(result) do
    case result do
      {:ok, meta, response_body} when is_map(meta) and is_binary(response_body) ->
        {:ok, meta, response_body}

      {:error, %{"type" => type, "message" => message, "details" => details}}
      when is_binary(type) and is_binary(message) ->
        error_type = to_error_type(type)
        {:error, Error.new(error_type, message, details)}

      other ->
        unexpected_native_response(other)
    end
  end

  @spec unexpected_native_response(term()) :: {:error, Error.t()}
  defp unexpected_native_response(response) do
    {:error, Error.new(:native_error, "unexpected native response", %{response: inspect(response)})}
  end

  defp safe_nif_perform_request(payload, body, token, cookie_jar_ref) do
    nif_perform_request(payload, body, token, cookie_jar_ref)
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
  defp nif_perform_request(_payload, _body, _token, _cookie_jar_ref), do: :erlang.nif_error(:nif_not_loaded)
end
