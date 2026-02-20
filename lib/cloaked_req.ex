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
  alias CloakedReq.Request
  alias CloakedReq.Response

  @custom_req_options [:cookie_jar, :impersonate, :insecure_skip_verify, :max_body_size]

  @doc """
  Attaches `CloakedReq` adapter behavior to an existing `Req.Request`.

  Supported custom adapter options:

  - `:cookie_jar` - `%CloakedReq.CookieJar{}` for automatic cookie persistence
  - `:impersonate` - profile atom (e.g. `:chrome_136`, `:"safari_17.4.1"`)
  - `:insecure_skip_verify` - boolean
  - `:max_body_size` - positive integer or `:unlimited` (default: 10 MB)

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

    with :ok <- validate_cookie_jar(jar),
         jar_ref = if(jar, do: jar.ref),
         {:ok, {payload, body}} <- Request.to_native_payload(request),
         {:ok, response_meta, response_body} <- Native.perform_request(payload, body, jar_ref),
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

  @spec register_options(Req.Request.t()) :: Req.Request.t()
  defp register_options(%Req.Request{} = request) do
    Req.Request.register_options(request, @custom_req_options)
  end

  @spec put_adapter(Req.Request.t()) :: Req.Request.t()
  defp put_adapter(%Req.Request{} = request) do
    %{request | adapter: &run/1}
  end
end
