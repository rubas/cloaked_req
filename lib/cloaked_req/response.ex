defmodule CloakedReq.Response do
  @moduledoc """
  Converts a native response meta map and body binary (from the Rust NIF)
  into a `Req.Response`.
  """

  alias CloakedReq.Error
  alias Req.Response, as: ReqResponse

  @doc """
  Builds a `Req.Response` from the native response metadata and body binary.

  Expects atom-keyed `:status` and `:headers` in the metadata map (produced by
  Rustler's NifMap). Headers arrive as `{name, value}` tuples directly from Rust.
  Returns `{:ok, %Req.Response{}}` or `{:error, %CloakedReq.Error{}}`.
  """
  @spec from_native(map(), binary()) :: {:ok, ReqResponse.t()} | {:error, Error.t()}
  def from_native(%{status: status, headers: headers} = meta, body)
      when is_integer(status) and status > 0 and is_list(headers) and is_binary(body) do
    response = ReqResponse.new(status: status, headers: headers, body: body)

    response =
      case meta do
        %{url: url} when is_binary(url) and url != "" ->
          ReqResponse.put_private(response, :cloaked_req_url, url)

        _ ->
          response
      end

    {:ok, response}
  end

  def from_native(_meta, _body) do
    {:error, Error.new(:invalid_native_response, "native response has an invalid shape")}
  end
end
