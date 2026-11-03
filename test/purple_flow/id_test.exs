defmodule PurpleFlow.IdTest do
  use ExUnit.Case, async: true

  alias PurpleFlow.Id

  doctest Id

  test "every ID is different, even many made at once" do
    ids = for _ <- 1..1_000, do: Id.generate()
    assert length(Enum.uniq(ids)) == 1_000
  end

  test "the leading 48 bits are the time in milliseconds" do
    before = System.system_time(:millisecond)
    [a, b | _] = String.split(Id.generate(), "-")
    {ms, ""} = Integer.parse(a <> b, 16)
    assert ms >= before and ms <= System.system_time(:millisecond)
  end
end
