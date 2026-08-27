defmodule CloakedReqTest do
  @moduledoc """
  Verifies public adapter helper APIs exposed by `CloakedReq`.
  """

  use ExUnit.Case, async: true

  alias CloakedReq.Error

  doctest CloakedReq, import: false
  doctest Error, import: false

  test "attach/2 sets CloakedReq adapter on request" do
    request = [url: "https://example.com"] |> Req.new() |> CloakedReq.attach()

    assert request.adapter == CloakedReq
  end

  test "impersonate/2 sets profile and adapter on request" do
    request = [url: "https://example.com"] |> Req.new() |> CloakedReq.impersonate(:firefox_136)

    assert request.adapter == CloakedReq
    assert Req.Request.get_option(request, :impersonate) == :firefox_136
  end

  test "attach/2 rejects unknown options" do
    assert_raise ArgumentError, "unknown option :unknown", fn ->
      [url: "https://example.com"] |> Req.new() |> CloakedReq.attach(unknown: :value)
    end
  end
end
