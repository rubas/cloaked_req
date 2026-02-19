defmodule CloakedReq.Request do
  @moduledoc """
  Converts a `Req.Request` into the JSON-serializable map expected by the Rust NIF.

  Validates and normalizes all adapter options (impersonate, timeout, body size,
  TLS verification) and encodes the request body as base64.
  """

  alias CloakedReq.Error

  @default_max_body_size 10_485_760

  @doc """
  Builds a native payload map from a `Req.Request`.

  Validates the request (URL scheme, body encoding, adapter options) and returns
  `{:ok, payload}` or `{:error, %CloakedReq.Error{}}`.
  """
  @spec to_native_payload(Req.Request.t()) :: {:ok, map()} | {:error, Error.t()}
  def to_native_payload(%Req.Request{} = request) do
    with :ok <- validate_into(request),
         :ok <- validate_url(request.url),
         flat_headers = flatten_headers(request.headers),
         {:ok, max_body_size} <-
           normalize_max_body_size(Req.Request.get_option(request, :max_body_size, @default_max_body_size)),
         {:ok, body} <- normalize_body(request.body, max_body_size),
         {:ok, emulation} <- normalize_impersonate(Req.Request.get_option(request, :impersonate)),
         {:ok, receive_timeout} <-
           normalize_receive_timeout(Req.Request.get_option(request, :receive_timeout, 15_000)),
         {:ok, insecure_skip_verify} <-
           normalize_insecure_skip_verify(Req.Request.get_option(request, :insecure_skip_verify, false)) do
      {:ok,
       %{
         "method" => request.method |> Atom.to_string() |> String.upcase(),
         "url" => URI.to_string(request.url),
         "headers" => Enum.map(flat_headers, fn {name, value} -> [name, value] end),
         "body_base64" => if(is_binary(body), do: Base.encode64(body)),
         "receive_timeout_ms" => receive_timeout,
         "emulation" => emulation,
         "insecure_skip_verify" => insecure_skip_verify,
         "max_body_size_bytes" => max_body_size
       }}
    end
  end

  @spec validate_into(Req.Request.t()) :: :ok | {:error, Error.t()}
  defp validate_into(%Req.Request{into: nil}), do: :ok

  defp validate_into(%Req.Request{}) do
    {:error, Error.new(:invalid_request, "streaming into is not supported by CloakedReq adapter")}
  end

  @spec validate_url(URI.t()) :: :ok | {:error, Error.t()}
  defp validate_url(%URI{scheme: scheme, host: host}) when scheme in ["http", "https"] and is_binary(host), do: :ok

  defp validate_url(_uri) do
    {:error, Error.new(:invalid_request, "url must be an absolute http(s) URL")}
  end

  @spec normalize_max_body_size(term()) :: {:ok, pos_integer() | nil} | {:error, Error.t()}
  defp normalize_max_body_size(:unlimited), do: {:ok, nil}
  defp normalize_max_body_size(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp normalize_max_body_size(_value) do
    {:error, Error.new(:invalid_request, "max_body_size must be a positive integer or :unlimited")}
  end

  @spec normalize_body(term(), pos_integer() | nil) :: {:ok, nil | binary()} | {:error, Error.t()}
  defp normalize_body(nil, _max), do: {:ok, nil}

  defp normalize_body(body, max) when is_binary(body) do
    if max && byte_size(body) > max do
      {:error, Error.new(:invalid_request, "request body exceeds max_body_size", %{size: byte_size(body), limit: max})}
    else
      {:ok, body}
    end
  end

  defp normalize_body(body, max) do
    size = :erlang.iolist_size(body)

    if max && size > max do
      {:error, Error.new(:invalid_request, "request body exceeds max_body_size", %{size: size, limit: max})}
    else
      {:ok, IO.iodata_to_binary(body)}
    end
  rescue
    ArgumentError ->
      {:error, Error.new(:invalid_request, "request body must be binary or iodata")}
  end

  @spec flatten_headers(map()) :: [{String.t(), String.t()}]
  defp flatten_headers(headers) when is_map(headers) do
    Enum.flat_map(headers, fn {name, values} ->
      for value <- List.wrap(values), do: {name, value}
    end)
  end

  @spec normalize_impersonate(term()) :: {:ok, nil | String.t()} | {:error, Error.t()}
  defp normalize_impersonate(nil), do: {:ok, nil}
  defp normalize_impersonate(value) when is_atom(value), do: {:ok, Atom.to_string(value)}

  defp normalize_impersonate(_value) do
    {:error, Error.new(:invalid_request, "impersonate must be a profile atom")}
  end

  @spec normalize_receive_timeout(term()) :: {:ok, pos_integer()} | {:error, Error.t()}
  defp normalize_receive_timeout(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp normalize_receive_timeout(_value) do
    {:error, Error.new(:invalid_request, "receive_timeout must be a positive integer")}
  end

  @spec normalize_insecure_skip_verify(term()) :: {:ok, boolean()} | {:error, Error.t()}
  defp normalize_insecure_skip_verify(value) when is_boolean(value), do: {:ok, value}

  defp normalize_insecure_skip_verify(_value) do
    {:error, Error.new(:invalid_request, "insecure_skip_verify must be a boolean")}
  end
end
