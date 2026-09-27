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

  alias PurpleFlow.StreamParser

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
        parser = Req.Response.get_private(resp, :parser, StreamParser.new())
        {items, parser} = StreamParser.parse(protocol, parser, data)

        Enum.each(items, &PurpleFlow.Node.emit/1)
        {:cont, {req, Req.Response.put_private(resp, :parser, parser)}}
      else
        {:cont, {req, %{resp | body: resp.body <> data}}}
      end
    end

    # No compression: the body is read as raw bytes, not decoded at the end.
    case Req.request(options ++ [into: into, compressed: false]) do
      {:ok, %Req.Response{status: status} = resp} when status in 200..299 ->
        parser = Req.Response.get_private(resp, :parser, StreamParser.new())
        Enum.each(StreamParser.finish(protocol, parser), &PurpleFlow.Node.emit/1)
        {:ok, []}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, "HTTP #{status}: #{preview(body)}"}

      {:error, error} ->
        {:error, "request failed: #{Exception.message(error)}"}
    end
  end

  defp body(nil), do: []
  defp body(body) when is_map(body) or is_list(body), do: [json: body]
  defp body(body), do: [body: to_string(body)]

  defp preview(body) when is_binary(body), do: String.slice(body, 0, 500)
  defp preview(body), do: body |> Jason.encode!() |> String.slice(0, 500)
end
