defmodule CloakedReq do
  @moduledoc """
  Req adapter powered by Rust `wreq`.

  - `attach/2` — set adapter and merge options
  - `impersonate/2` — set browser profile
  """

  alias CloakedReq.AdapterError
  alias CloakedReq.CookieJar
  alias CloakedReq.Error
  alias CloakedReq.Native
  alias CloakedReq.Pool
  alias CloakedReq.Request
  alias CloakedReq.Response

  @custom_req_options [:cookie_jar, :impersonate, :insecure_skip_verify, :local_address, :max_body_size, :pool]

  @doc """
  Attaches `CloakedReq` adapter behavior to an existing `Req.Request`.

  Supported adapter-relevant options:

  - `:cookie_jar` - `%CloakedReq.CookieJar{}` for automatic cookie persistence
  - `:connect_options` - Req transport options for `:timeout`, `:proxy`, and `:proxy_headers`
  - `:impersonate` - profile atom (e.g. `:chrome_136`, `:"safari_17.4.1"`)
  - `:insecure_skip_verify` - boolean
  - `:local_address` - outbound source IP as string, IPv4 tuple, or IPv6 tuple
  - `:max_body_size` - positive integer or `:unlimited` (default: 10 MB); caps
    both the request body (rejected before sending if larger) and the response
    body (truncated to an error once it exceeds the limit)
  - `:pool` - `%CloakedReq.Pool{}` built with `CloakedReq.Pool.new/1`, routing
    the request through a dedicated, isolated client and connection pool. The
    pool's client governs the impersonation profile, TLS verification, and
    connect timeout, so per-request `:impersonate`, `:insecure_skip_verify`, and
    the `:connect_options` connect timeout are ignored (still validated if
    given). The `:connect_options` proxy, `:local_address`, headers, body,
    `:cookie_jar`, and `:receive_timeout` still apply per request.

  ## Examples

      iex> req = Req.new(url: "https://example.com") |> CloakedReq.attach(impersonate: :chrome_136)
      iex> is_function(req.adapter, 1)
      true
      iex> Req.Request.get_option(req, :impersonate)
      :chrome_136
  """
  @spec attach(Req.Request.t(), keyword()) :: Req.Request.t()
  def attach(%Req.Request{} = request, options \\ []) when is_list(options) do
    request
    |> register_options()
    |> Req.Request.merge_options(options)
    |> put_adapter()
  end

  @doc """
  Sets the impersonation profile and configures the `CloakedReq` Req adapter.

  ## Examples

      iex> req = Req.new(url: "https://example.com") |> CloakedReq.impersonate(:chrome_136)
      iex> Req.Request.get_option(req, :impersonate)
      :chrome_136
      iex> is_function(req.adapter, 1)
      true
  """
  @spec impersonate(Req.Request.t(), atom()) :: Req.Request.t()
  def impersonate(%Req.Request{} = request, profile) do
    request
    |> register_options()
    |> Req.Request.put_option(:impersonate, profile)
    |> put_adapter()
  end

  @doc false
  @spec run(Req.Request.t()) :: {Req.Request.t(), Req.Response.t() | Exception.t()}
  def run(%Req.Request{} = request) do
    jar = Req.Request.get_option(request, :cookie_jar, nil)
    pool = Req.Request.get_option(request, :pool, nil)

    with :ok <- validate_cookie_jar(jar),
         :ok <- validate_pool(pool),
         jar_ref = if(jar, do: jar.ref),
         pool_ref = if(pool, do: pool.ref),
         {:ok, {payload, body}} <- Request.to_native_payload(request),
         payload = apply_pool_connect_timeout(payload, pool),
         {:ok, response_meta, response_body} <-
           Native.perform_request(payload, body, jar_ref, pool_ref),
         {:ok, req_response} <- Response.from_native(response_meta, response_body) do
      {request, req_response}
    else
      {:error, %Error{} = error} ->
        {request, AdapterError.exception(error)}
    end
  end

  @spec validate_cookie_jar(nil | CookieJar.t()) :: :ok | {:error, Error.t()}
  defp validate_cookie_jar(nil), do: :ok
  defp validate_cookie_jar(%CookieJar{}), do: :ok

  defp validate_cookie_jar(_value) do
    {:error, Error.new(:invalid_request, "cookie_jar must be a %CloakedReq.CookieJar{}")}
  end

  @spec validate_pool(nil | Pool.t()) :: :ok | {:error, Error.t()}
  defp validate_pool(nil), do: :ok
  defp validate_pool(%Pool{}), do: :ok

  defp validate_pool(_value) do
    {:error, Error.new(:invalid_request, "pool must be a %CloakedReq.Pool{}")}
  end

  # A pooled client carries its own connect timeout, so the per-request value in
  # the payload no longer bounds the native connect. Replace it with the pool's
  # so the BEAM-side response backstop matches the real native deadline.
  @spec apply_pool_connect_timeout(map(), nil | Pool.t()) :: map()
  defp apply_pool_connect_timeout(payload, nil), do: payload

  defp apply_pool_connect_timeout(payload, %Pool{connect_timeout: connect_timeout}) do
    %{payload | connect_timeout_ms: connect_timeout}
  end

  @spec register_options(Req.Request.t()) :: Req.Request.t()
  defp register_options(%Req.Request{} = request) do
    Req.Request.register_options(request, @custom_req_options)
  end

  @spec put_adapter(Req.Request.t()) :: Req.Request.t()
  defp put_adapter(%Req.Request{} = request) do
    %{request | adapter: &run/1}
  end
end
