defmodule CloakedReq.Native do
  @moduledoc """
  Rust NIF interface for HTTP request execution via `wreq`.

  Handles JSON serialization of request payloads, NIF invocation, and
  deserialization of native response/error payloads.
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
      aarch64-unknown-linux-musl
      x86_64-apple-darwin
      x86_64-pc-windows-msvc
      x86_64-unknown-linux-gnu
      x86_64-unknown-linux-musl
    )

  alias CloakedReq.Error

  @doc """
  Encodes the payload as JSON, sends it to the Rust NIF, and decodes the result.

  Returns `{:ok, response_map}` or `{:error, %CloakedReq.Error{}}`.
  """
  @spec perform_request(map()) :: {:ok, map()} | {:error, Error.t()}
  def perform_request(payload) when is_map(payload) do
    payload
    |> JSON.encode!()
    |> safe_nif_perform_request()
    |> decode_native_result()
  rescue
    error in [Protocol.UndefinedError] ->
      {:error, Error.new(:invalid_request, "request payload encoding failed", %{reason: Exception.message(error)})}
  end

  def perform_request(_value) do
    {:error, Error.new(:invalid_request, "native payload must be a map")}
  end

  @spec decode_native_result({:ok, String.t()} | {:error, String.t()} | term()) :: {:ok, map()} | {:error, Error.t()}
  defp decode_native_result({:ok, json}) when is_binary(json) do
    case JSON.decode(json) do
      {:ok, decoded} when is_map(decoded) ->
        {:ok, decoded}

      {:ok, _value} ->
        {:error, Error.new(:invalid_native_response, "native success payload must decode to a map")}

      {:error, reason} ->
        {:error,
         Error.new(:invalid_native_response, "cannot decode native success payload", %{reason: inspect(reason)})}
    end
  end

  defp decode_native_result({:error, json}) when is_binary(json) do
    case JSON.decode(json) do
      {:ok, %{"type" => type, "message" => message} = details} when is_binary(type) and is_binary(message) ->
        {:error,
         Error.new(
           to_error_type(type),
           message,
           details |> Map.delete("type") |> Map.delete("message")
         )}

      {:ok, _value} ->
        {:error, Error.new(:native_error, "native error payload had invalid shape", %{payload: json})}

      {:error, reason} ->
        {:error,
         Error.new(:native_error, "cannot decode native error payload", %{reason: inspect(reason), payload: json})}
    end
  end

  defp decode_native_result(other) do
    {:error, Error.new(:native_error, "unexpected native response", %{response: inspect(other)})}
  end

  @spec to_error_type(String.t()) :: atom()
  defp safe_nif_perform_request(json) do
    nif_perform_request(json)
  rescue
    error in [ErlangError] ->
      {:error, JSON.encode!(%{type: "nif_panic", message: Exception.message(error), details: %{}})}
  end

  defp to_error_type("nif_panic"), do: :nif_panic
  defp to_error_type("decode_request"), do: :decode_request
  defp to_error_type("invalid_request"), do: :invalid_request
  defp to_error_type("transport_error"), do: :transport_error
  defp to_error_type("runtime_error"), do: :runtime_error
  defp to_error_type("invalid_native_response"), do: :invalid_native_response
  defp to_error_type(_), do: :native_error

  defp nif_perform_request(_json_payload), do: :erlang.nif_error(:nif_not_loaded)
end
