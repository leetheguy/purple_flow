defmodule PurpleFlow.Nodes.Http do
  @moduledoc """
  Makes an HTTP request with `Req`.

      module = "PurpleFlow.Nodes.Http"

      [config]
      method = "POST"                       # default "GET"
      url = "https://api.example.com/items"
      headers = { authorization = "Bearer {{ creds.API_TOKEN }}" }
      query = { page = 1 }                  # optional
      body = { name = "{{ input.name }}" }  # optional; maps/lists are sent as JSON
      stream = "sse"                        # optional: "sse", "ndjson", or "lines"

  Output is the response body (decoded if it's JSON). A non-2xx response is
  an error. No retries: a failure fails loud.

  With `stream`, the response is read as it arrives and each message in it
  is handed on right away (`PurpleFlow.Node.emit/2`), following the
  protocol named: one server-sent event, one line of JSON, or one line of
  text. See `specs/150_streaming.md`.
  """

  @behaviour PurpleFlow.Node

  @protocols ~w(sse ndjson lines)

  @impl true
  def prepare(config, _node_dir, _root) do
    case config["stream"] do
      nil -> {:ok, config}
      protocol when protocol in @protocols -> {:ok, config}
      other -> {:error, ~s(stream must be "sse", "ndjson", or "lines", not #{inspect(other)})}
    end
  end

  @impl true
  def execute(_input, config) do
    options =
      [
        method:
          config |> Map.get("method", "GET") |> String.downcase() |> String.to_existing_atom(),
        url: Map.fetch!(config, "url"),
        headers: Map.get(config, "headers", %{}),
        params: Map.get(config, "query", %{}),
        retry: false
      ] ++ body(config["body"]) ++ Application.get_env(:purple_flow, :http_req_options, [])

    case config["stream"] do
      nil -> request(options)
      protocol -> stream(options, protocol)
    end
  end

  defp request(options) do
    case Req.request(options) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, "HTTP #{status}: #{preview(body)}"}

      {:error, error} ->
        {:error, "request failed: #{Exception.message(error)}"}
    end
  end

  # Reads the body as it arrives. A success hands on each message as soon
  # as it's complete; a failure just keeps the body for the error message.
  defp stream(options, protocol) do
    into = fn {:data, data}, {req, resp} ->
      if resp.status in 200..299 do
        {items, parser} =
          parse(protocol, Req.Response.get_private(resp, :parser, new_parser()), data)

        Enum.each(items, &PurpleFlow.Node.emit/1)
        {:cont, {req, Req.Response.put_private(resp, :parser, parser)}}
      else
        {:cont, {req, %{resp | body: resp.body <> data}}}
      end
    end

    # No compression: the body is read as raw bytes, not decoded at the end.
    case Req.request(options ++ [into: into, compressed: false]) do
      {:ok, %Req.Response{status: status} = resp} when status in 200..299 ->
        parser = Req.Response.get_private(resp, :parser, new_parser())
        Enum.each(finish(protocol, parser), &PurpleFlow.Node.emit/1)
        {:ok, []}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, "HTTP #{status}: #{preview(body)}"}

      {:error, error} ->
        {:error, "request failed: #{Exception.message(error)}"}
    end
  end

  # -- reading streamed messages --

  @doc false
  # Where a parse left off: text not yet ending in a newline, and the
  # server-sent event being built.
  def new_parser, do: %{buffer: "", event: nil, data: [], id: nil}

  @doc false
  # Takes the next chunk of the body. Returns the messages it completed,
  # as items, and where it left off.
  def parse(protocol, parser, chunk) do
    {lines, rest} = lines(parser.buffer <> chunk)
    parser = %{parser | buffer: rest}

    case protocol do
      "sse" -> Enum.flat_map_reduce(lines, parser, &sse_line/2)
      "ndjson" -> {lines |> Enum.reject(&(&1 == "")) |> Enum.map(&json_line/1), parser}
      "lines" -> {Enum.reject(lines, &(&1 == "")), parser}
    end
  end

  @doc false
  # The body ended. A last line with no newline still counts; an unfinished
  # server-sent event doesn't.
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

  defp body(nil), do: []
  defp body(body) when is_map(body) or is_list(body), do: [json: body]
  defp body(body), do: [body: to_string(body)]

  defp preview(body) when is_binary(body), do: String.slice(body, 0, 500)
  defp preview(body), do: body |> Jason.encode!() |> String.slice(0, 500)
end
