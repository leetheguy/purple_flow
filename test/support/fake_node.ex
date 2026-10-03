defmodule PurpleFlow.Test.FakeNode do
  @moduledoc """
  A node for tests. Its config says what to do:

  - `"return"`: return this value (otherwise the input comes back unchanged)
  - `"fail_if"`: fail when the input equals this value
  - `"raise"`: raise an exception
  - `"crash"`: kill its own process
  - `"sleep"`: wait this many milliseconds first
  - `"sleep_input"`: wait as many milliseconds as the input says
  - `"route_over"`: route `"big"` if the input is over this number, else `"small"`
  - `"explode"`: return a list of this many copies of the input
  - `"emit"`: emit each of these values while running (`"emit_sleep"` ms
    apart), then wait `"after_emit"` ms and return `[]`
  - `"stream_reply"`: answer the waiting webhook caller with a stream of
    these chunks, without ending it, before anything else (so `"crash"`
    after it leaves the stream open)
  """

  @behaviour PurpleFlow.Node

  @impl true
  def execute(input, config) do
    if chunks = config["stream_reply"] do
      {:ok, sink} = PurpleFlow.Node.respond_stream(200, %{"content-type" => "text/event-stream"})
      Enum.each(chunks, &PurpleFlow.Node.respond_chunk(sink, &1))
    end

    if ms = config["sleep"], do: Process.sleep(ms)
    if config["sleep_input"], do: Process.sleep(input)
    if config["raise"], do: raise("kaboom")
    if config["crash"], do: Process.exit(self(), :kill)

    cond do
      Map.has_key?(config, "fail_if") and input == config["fail_if"] ->
        {:error, "boom on #{inspect(input)}"}

      emit = config["emit"] ->
        for value <- emit do
          PurpleFlow.Node.emit(value)
          if ms = config["emit_sleep"], do: Process.sleep(ms)
        end

        if ms = config["after_emit"], do: Process.sleep(ms)
        {:ok, []}

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
