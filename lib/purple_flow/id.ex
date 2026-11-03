defmodule PurpleFlow.Id do
  @moduledoc """
  Makes run IDs. Each one is a UUIDv7: a normal-looking UUID that starts with
  a timestamp, so newer IDs sort after older ones.

  Hand-written (copied from purple_goo) because it's a few lines and not worth
  a dependency.

  See [specs/050](specs/050_storage.md).
  """

  @doc ~S"""
  A fresh UUIDv7 string. The version digit (the first of the third group)
  is always `7`. An ID made in a later millisecond sorts after an earlier
  one; within the same millisecond, the order is random.

      iex> PurpleFlow.Id.generate() =~ ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/
      true
  """
  @spec generate() :: String.t()
  def generate do
    unix_ts_ms = System.system_time(:millisecond)

    # Grab 10 random bytes and split them into the two random fields a v7 UUID
    # needs (12 bits and 62 bits). The last 6 bits are thrown away.
    <<rand_a::12, rand_b::62, _::6>> = :crypto.strong_rand_bytes(10)

    # Lay out the 128 bits in the order the UUID standard says:
    # timestamp, version (7), random, variant marker, random.
    <<uuid::128>> = <<unix_ts_ms::48, 0b0111::4, rand_a::12, 0b10::2, rand_b::62>>

    uuid
    |> Integer.to_string(16)
    |> String.downcase()
    |> String.pad_leading(32, "0")
    |> format()
  end

  # Turn 32 hex characters into the usual 8-4-4-4-12 dashed form.
  defp format(<<a::binary-8, b::binary-4, c::binary-4, d::binary-4, e::binary-12>>) do
    "#{a}-#{b}-#{c}-#{d}-#{e}"
  end
end
