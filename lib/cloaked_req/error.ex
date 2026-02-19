defmodule CloakedReq.Error do
  @moduledoc """
  Represents explicit error information returned by `CloakedReq`.
  """

  @enforce_keys [:type, :message]
  defstruct [:type, :message, details: %{}]

  @type t :: %__MODULE__{
          type: atom(),
          message: String.t(),
          details: map()
        }

  @doc """
  Builds a structured error value.

  ## Examples

      iex> err = CloakedReq.Error.new(:invalid_request, "missing url")
      iex> err.type
      :invalid_request
  """
  @spec new(atom(), String.t(), map()) :: t()
  def new(type, message, details \\ %{}) when is_atom(type) and is_binary(message) and is_map(details) do
    %__MODULE__{type: type, message: message, details: details}
  end

  @doc """
  Formats an error into a user-facing string.

  ## Examples

      iex> CloakedReq.Error.new(:invalid_request, "missing url") |> CloakedReq.Error.format()
      "invalid_request: missing url"
  """
  @spec format(t()) :: String.t()
  def format(%__MODULE__{type: type, message: message}) do
    "#{type}: #{message}"
  end
end
