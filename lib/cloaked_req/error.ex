defmodule CloakedReq.Error do
  @moduledoc """
  Represents explicit error information returned by `CloakedReq`.
  """

  @enforce_keys [:type, :message]
  defstruct [:type, :message, details: %{}]

  @type type :: :invalid_request | :transport_error | :nif_panic

  @type t :: %__MODULE__{
          type: type(),
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
  @spec new(type(), String.t(), map()) :: t()
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
