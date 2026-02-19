defmodule CloakedReq.Response do
  @moduledoc """
  Converts a native response map (from the Rust NIF) into a `Req.Response`.

  Decodes base64-encoded body and validates header structure.
  """

  alias CloakedReq.Error
  alias Req.Response, as: ReqResponse

  @doc """
  Builds a `Req.Response` from the native response map.

  Expects `"status"`, `"headers"`, and `"body_base64"` keys. Returns
  `{:ok, %Req.Response{}}` or `{:error, %CloakedReq.Error{}}`.
  """
  @spec from_native(map()) :: {:ok, ReqResponse.t()} | {:error, Error.t()}
  def from_native(%{"status" => status, "headers" => headers, "body_base64" => body_base64})
      when is_integer(status) and status > 0 and is_list(headers) and is_binary(body_base64) do
    with {:ok, decoded_headers} <- decode_headers(headers),
         {:ok, body} <- decode_body(body_base64) do
      {:ok, ReqResponse.new(status: status, headers: decoded_headers, body: body)}
    end
  end

  def from_native(_value) do
    {:error, Error.new(:invalid_native_response, "native response has an invalid shape")}
  end

  @spec decode_headers(list()) :: {:ok, [{String.t(), String.t()}]} | {:error, Error.t()}
  defp decode_headers(headers) do
    headers
    |> Enum.reduce_while({:ok, []}, fn
      [name, value], {:ok, acc} when is_binary(name) and is_binary(value) ->
        {:cont, {:ok, [{name, value} | acc]}}

      header, _acc ->
        {:halt,
         {:error,
          Error.new(:invalid_native_response, "native response headers must be string pairs", %{header: header})}}
    end)
    |> then(fn
      {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
      {:error, _} = error -> error
    end)
  end

  @spec decode_body(String.t()) :: {:ok, binary()} | {:error, Error.t()}
  defp decode_body(body_base64) do
    case Base.decode64(body_base64) do
      {:ok, body} -> {:ok, body}
      :error -> {:error, Error.new(:invalid_native_response, "body_base64 is not valid base64")}
    end
  end
end
