defmodule CloakedReq.Response do
  @moduledoc """
  Converts a native response meta map and body binary (from the Rust NIF)
  into a `Req.Response`.
  """

  alias Req.Response, as: ReqResponse

  @doc """
  Builds a `Req.Response` from the native response metadata and body binary.

  Expects atom-keyed `:status` and `:headers` in the metadata map (produced by
  Rustler's NifMap). Headers arrive as `{name, value}` tuples directly from Rust.
  """
  @spec from_native(%{status: pos_integer(), headers: [{String.t(), String.t()}]}, binary()) :: ReqResponse.t()
  def from_native(%{status: status, headers: headers}, body) do
    ReqResponse.new(status: status, headers: headers, body: body)
  end
end
