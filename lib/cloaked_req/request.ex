defmodule CloakedReq.Request do
  @moduledoc """
  Converts a `Req.Request` into the metadata map and body expected by the Rust NIF.

  Validates and normalizes all adapter options (impersonate, timeouts, proxy,
  body size, TLS verification). The metadata map is passed to `CloakedReq.Native`;
  the body is passed as a raw binary.
  """

  import Req.Request, only: [get_option: 2, get_option: 3]

  alias CloakedReq.Error

  @default_max_body_size 10_485_760
  @default_connect_timeout 30_000
  @supported_connect_options MapSet.new([:timeout, :proxy, :proxy_headers])

  @doc """
  Builds a native payload tuple from a `Req.Request`.

  Validates the request (URL scheme, body encoding, adapter options) and returns
  `{:ok, {metadata_map, body_binary}}` or `{:error, %CloakedReq.Error{}}`.
  """
  @spec to_native_payload(Req.Request.t()) :: {:ok, {map(), binary() | nil}} | {:error, Error.t()}
  def to_native_payload(%Req.Request{} = request) do
    with :ok <- validate_into(request),
         :ok <- validate_url(request.url),
         flat_headers = flatten_headers(request.headers),
         {:ok, max_body_size} <-
           normalize_max_body_size(get_option(request, :max_body_size, @default_max_body_size)),
         {:ok, body} <- normalize_body(request.body, max_body_size),
         {:ok, emulation} <- normalize_impersonate(get_option(request, :impersonate)),
         {:ok, receive_timeout} <-
           normalize_receive_timeout(get_option(request, :receive_timeout, 15_000)),
         {:ok, connect_options} <-
           normalize_connect_options(get_option(request, :connect_options, [])),
         {:ok, insecure_skip_verify} <-
           normalize_insecure_skip_verify(get_option(request, :insecure_skip_verify, false)),
         {:ok, local_address} <-
           normalize_local_address(get_option(request, :local_address)) do
      {:ok,
       {%{
          method: request.method |> Atom.to_string() |> String.upcase(),
          url: URI.to_string(request.url),
          headers: flat_headers,
          receive_timeout_ms: receive_timeout,
          connect_timeout_ms: connect_options.timeout,
          proxy: connect_options.proxy,
          emulation: emulation,
          insecure_skip_verify: insecure_skip_verify,
          max_body_size_bytes: max_body_size,
          local_address: local_address
        }, body}}
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

  @spec normalize_connect_options(term()) ::
          {:ok, %{timeout: pos_integer(), proxy: nil | map()}} | {:error, Error.t()}
  defp normalize_connect_options(nil), do: {:ok, %{timeout: @default_connect_timeout, proxy: nil}}

  defp normalize_connect_options(options) when is_list(options) do
    if Keyword.keyword?(options) do
      with :ok <- validate_connect_option_keys(options),
           {:ok, timeout} <- normalize_connect_timeout(Keyword.get(options, :timeout, @default_connect_timeout)),
           {:ok, proxy} <- normalize_proxy(Keyword.get(options, :proxy), Keyword.get(options, :proxy_headers, [])) do
        {:ok, %{timeout: timeout, proxy: proxy}}
      end
    else
      {:error, Error.new(:invalid_request, "connect_options must be a keyword list")}
    end
  end

  defp normalize_connect_options(_value) do
    {:error, Error.new(:invalid_request, "connect_options must be a keyword list")}
  end

  @spec validate_connect_option_keys(keyword()) :: :ok | {:error, Error.t()}
  defp validate_connect_option_keys(options) do
    unsupported =
      options
      |> Keyword.keys()
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(@supported_connect_options, &1))

    case unsupported do
      [] ->
        :ok

      keys ->
        names = Enum.map_join(keys, ", ", &inspect/1)
        {:error, Error.new(:invalid_request, "unsupported connect_options for CloakedReq adapter: #{names}")}
    end
  end

  @spec normalize_connect_timeout(term()) :: {:ok, pos_integer()} | {:error, Error.t()}
  defp normalize_connect_timeout(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp normalize_connect_timeout(_value) do
    {:error, Error.new(:invalid_request, "connect_options timeout must be a positive integer")}
  end

  @spec normalize_proxy(term(), term()) :: {:ok, nil | map()} | {:error, Error.t()}
  defp normalize_proxy(nil, []), do: {:ok, nil}

  defp normalize_proxy(nil, _headers) do
    {:error, Error.new(:invalid_request, "connect_options proxy_headers require proxy")}
  end

  defp normalize_proxy({scheme, host, port, []}, headers)
       when scheme in [:http, :https] and is_binary(host) and is_integer(port) and port > 0 do
    with {:ok, proxy_headers} <- normalize_proxy_headers(headers) do
      {:ok,
       %{
         url: "#{scheme}://#{host}:#{port}",
         headers: proxy_headers
       }}
    end
  end

  defp normalize_proxy({_scheme, _host, _port, _opts}, _headers) do
    {:error, Error.new(:invalid_request, "connect_options proxy options are not supported by CloakedReq adapter")}
  end

  defp normalize_proxy(_value, _headers) do
    {:error, Error.new(:invalid_request, "connect_options proxy must be {:http | :https, host, port, []}")}
  end

  @spec normalize_proxy_headers(term()) :: {:ok, [{String.t(), String.t()}]} | {:error, Error.t()}
  defp normalize_proxy_headers(headers) when is_list(headers) do
    result =
      Enum.reduce_while(headers, {:ok, []}, fn
        {name, value}, {:ok, acc} when is_binary(name) and is_binary(value) ->
          {:cont, {:ok, [{name, value} | acc]}}

        _header, _acc ->
          {:halt, {:error, Error.new(:invalid_request, "connect_options proxy_headers must be binary header pairs")}}
      end)

    case result do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp normalize_proxy_headers(headers) when is_map(headers) do
    headers
    |> flatten_headers()
    |> normalize_proxy_headers()
  end

  defp normalize_proxy_headers(_headers) do
    {:error, Error.new(:invalid_request, "connect_options proxy_headers must be a list or map")}
  end

  @spec normalize_insecure_skip_verify(term()) :: {:ok, boolean()} | {:error, Error.t()}
  defp normalize_insecure_skip_verify(value) when is_boolean(value), do: {:ok, value}

  defp normalize_insecure_skip_verify(_value) do
    {:error, Error.new(:invalid_request, "insecure_skip_verify must be a boolean")}
  end

  @spec normalize_local_address(term()) :: {:ok, nil | String.t()} | {:error, Error.t()}
  defp normalize_local_address(nil), do: {:ok, nil}

  defp normalize_local_address({a, b, c, d} = addr)
       when is_integer(a) and is_integer(b) and is_integer(c) and is_integer(d) do
    ntoa_to_string(addr)
  end

  defp normalize_local_address({a, b, c, d, e, f, g, h} = addr)
       when is_integer(a) and is_integer(b) and is_integer(c) and is_integer(d) and is_integer(e) and is_integer(f) and
              is_integer(g) and is_integer(h) do
    ntoa_to_string(addr)
  end

  defp normalize_local_address(value) when is_binary(value) do
    charlist = String.to_charlist(value)

    case :inet.parse_address(charlist) do
      {:ok, _addr} -> {:ok, value}
      {:error, _} -> {:error, Error.new(:invalid_request, "local_address is not a valid IP address")}
    end
  end

  defp normalize_local_address(_value) do
    {:error, Error.new(:invalid_request, "local_address must be an IP address string or tuple")}
  end

  @spec ntoa_to_string(:inet.ip_address()) :: {:ok, String.t()} | {:error, Error.t()}
  defp ntoa_to_string(addr) do
    case :inet.ntoa(addr) do
      {:error, _} -> {:error, Error.new(:invalid_request, "local_address is not a valid IP address")}
      charlist -> {:ok, List.to_string(charlist)}
    end
  end
end
