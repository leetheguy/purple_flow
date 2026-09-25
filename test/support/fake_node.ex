defmodule PurpleFlow.Test.FakeNode do
  @moduledoc """
  A node for tests. Its config says what to do:

  - `"return"`: return this value (otherwise the input comes back unchanged)
  - `"fail_if"`: fail when the input equals this value
  - `"raise"`: raise an exception
  - `"sleep"`: wait this many milliseconds first
  - `"route_over"`: route `"big"` if the input is over this number, else `"small"`
  - `"explode"`: return a list of this many copies of the input
  """

  @behaviour PurpleFlow.Node

  @impl true
  def execute(input, config) do
    if ms = config["sleep"], do: Process.sleep(ms)
    if config["raise"], do: raise("kaboom")

    cond do
      Map.has_key?(config, "fail_if") and input == config["fail_if"] ->
        {:error, "boom on #{inspect(input)}"}

      Map.has_key?(config, "return") ->
        {:ok, config["return"]}

      n = config["explode"] ->
        {:ok, List.duplicate(input, n)}

      over = config["route_over"] ->
        {:ok, input, if(input > over, do: "big", else: "small")}

      true ->
        {:ok, input}
    end
  end
end
