defmodule CloakedReq.AdapterError do
  @moduledoc """
  Exception wrapper returned by the Req adapter when `CloakedReq` fails.
  """

  alias CloakedReq.Error

  defexception [:message, :error]

  @type t :: %__MODULE__{
          message: String.t(),
          error: Error.t()
        }

  @spec exception(Error.t() | String.t()) :: t()
  def exception(%Error{} = error) do
    %__MODULE__{message: Error.format(error), error: error}
  end

  def exception(message) when is_binary(message) do
    error = Error.new(:native_error, message)
    %__MODULE__{message: message, error: error}
  end
end
