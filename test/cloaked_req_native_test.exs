defmodule CloakedReq.NativeTest do
  @moduledoc """
  Unit tests for the message backstop in `CloakedReq.Native.await_native_response/2`,
  the safety net that keeps a synchronous caller from hanging if the native task
  never sends its token-tagged reply.
  """

  use ExUnit.Case, async: true

  alias CloakedReq.Error
  alias CloakedReq.Native

  test "returns the native result when the reply is already queued" do
    token = make_ref()
    send(self(), {:cloaked_req_response, token, {:ok, %{status: 200}, "body"}})

    assert {:ok, %{status: 200}, "body"} = Native.await_native_response(token, 1_000)
  end

  test "ignores replies tagged with a different token" do
    token = make_ref()
    other = make_ref()
    send(self(), {:cloaked_req_response, other, {:ok, %{status: 200}, "stale"}})

    assert {:error, %Error{type: :transport_error}} = Native.await_native_response(token, 30)

    # The mismatched reply is left untouched for whoever owns that token.
    assert_received {:cloaked_req_response, ^other, _}
  end

  test "times out with a transport error when no reply arrives" do
    token = make_ref()

    assert {:error, %Error{type: :transport_error, details: %{timeout_ms: 25}}} =
             Native.await_native_response(token, 25)
  end
end
