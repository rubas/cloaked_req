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

  @spec exception(Error.t()) :: t()
  def exception(%Error{} = error) do
    %__MODULE__{message: Error.format(error), error: error}
  end
end
