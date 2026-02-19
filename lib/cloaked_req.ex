defmodule CloakedReq do
  @moduledoc """
  Req adapter utilities powered by Rust `wreq`.

  This library is intentionally adapter-first:

  - `attach/2` to set adapter and merge adapter options
  - `impersonate/2` to set browser profile quickly
  """

  alias CloakedReq.AdapterError
  alias CloakedReq.Error
  alias CloakedReq.Native
  alias CloakedReq.Request
  alias CloakedReq.Response

  @custom_req_options [:impersonate, :insecure_skip_verify, :max_body_size]

  @doc """
  Attaches `CloakedReq` adapter behavior to an existing `Req.Request`.

  Supported custom adapter options:

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
    with {:ok, payload} <- Request.to_native_payload(request),
         {:ok, native_response} <- Native.perform_request(payload),
         {:ok, req_response} <- Response.from_native(native_response) do
      {request, req_response}
    else
      {:error, %Error{} = error} ->
        {request, AdapterError.exception(error)}
    end
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
