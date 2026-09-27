defmodule PurpleFlow.StreamParser do
  @moduledoc """
  Splits a streamed body into messages as its chunks arrive, for the nodes
  that stream (`PurpleFlow.Nodes.Http`, `PurpleFlow.Nodes.Ssh`). See
  `specs/150_streaming.md`.

  - `"sse"`: one server-sent event per item, `{"event", "data", "id"}`
  - `"ndjson"`: one line of JSON per item, decoded
  - `"lines"`: one line of text per item

  Blank lines are skipped. Feed each chunk to `parse/3` and, when the body
  ends, call `finish/2` for anything left over.
  """

  @doc """
  Where a parse left off: text not yet ending in a newline, and the
  server-sent event being built.
  """
  def new, do: %{buffer: "", event: nil, data: [], id: nil}

  @doc """
  Takes the next chunk of the body. Returns the messages it completed, as
  items, and where it left off. A line of `ndjson` that isn't JSON raises.
  """
  def parse(protocol, parser, chunk) do
    {lines, rest} = lines(parser.buffer <> chunk)
    parser = %{parser | buffer: rest}

    case protocol do
      "sse" -> Enum.flat_map_reduce(lines, parser, &sse_line/2)
      "ndjson" -> {lines |> Enum.reject(&(&1 == "")) |> Enum.map(&json_line/1), parser}
      "lines" -> {Enum.reject(lines, &(&1 == "")), parser}
    end
  end

  @doc """
  The body ended. A last line with no newline still counts; an unfinished
  server-sent event doesn't.
  """
  def finish("sse", _parser), do: []
  def finish(_protocol, %{buffer: ""}), do: []
  def finish("ndjson", %{buffer: line}), do: [json_line(line)]
  def finish("lines", %{buffer: line}), do: [line]

  # Complete lines, without their line endings, and what's left over.
  defp lines(text) do
    {complete, [rest]} = text |> String.split("\n") |> Enum.split(-1)
    {Enum.map(complete, &String.trim_trailing(&1, "\r")), rest}
  end

  defp json_line(line) do
    case Jason.decode(line) do
      {:ok, value} -> value
      {:error, _} -> raise "streamed line isn't JSON: #{String.slice(line, 0, 200)}"
    end
  end

  # A blank line ends an event; other lines add to it. See the HTML spec's
  # "event stream interpretation".
  defp sse_line("", %{data: []} = parser), do: {[], %{parser | event: nil, id: nil}}

  defp sse_line("", parser) do
    data = parser.data |> Enum.reverse() |> Enum.join("\n")
    event = %{"event" => parser.event || "message", "data" => decode(data)}
    event = if parser.id, do: Map.put(event, "id", parser.id), else: event
    {[event], %{parser | event: nil, data: [], id: nil}}
  end

  defp sse_line(":" <> _comment, parser), do: {[], parser}

  defp sse_line(line, parser) do
    {field, value} =
      case String.split(line, ":", parts: 2) do
        [field, " " <> value] -> {field, value}
        [field, value] -> {field, value}
        [field] -> {field, ""}
      end

    case field do
      "data" -> {[], %{parser | data: [value | parser.data]}}
      "event" -> {[], %{parser | event: value}}
      "id" -> {[], %{parser | id: value}}
      _ -> {[], parser}
    end
  end

  defp decode(data) do
    case Jason.decode(data) do
      {:ok, value} -> value
      {:error, _} -> data
    end
  end
end
