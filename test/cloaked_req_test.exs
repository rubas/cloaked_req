defmodule CloakedReqTest do
  @moduledoc """
  Verifies public adapter helper APIs exposed by `CloakedReq`.
  """

  use ExUnit.Case, async: true

  alias CloakedReq.Error

  doctest CloakedReq, import: false
  doctest Error, import: false

  test "attach/2 rejects unknown options" do
    assert_raise ArgumentError, "unknown option :unknown", fn ->
      [url: "https://example.com"] |> Req.new() |> CloakedReq.attach(unknown: :value)
    end
  end
end
