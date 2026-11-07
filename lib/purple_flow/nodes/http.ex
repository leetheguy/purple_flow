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
      body_file = "{{ input.body.doc }}"    # optional, instead: a file's bytes
      form = { doc = "{{ input.body.doc }}" } # optional, instead: multipart/form-data
      stream = "sse"                        # optional: "sse", "ndjson", or "lines"

  Output is the response body (decoded if it's JSON). A non-2xx response is
  an error. No retries: a failure fails loud.

  With `stream`, the response is read as it arrives and each message in it
  is handed on right away (`PurpleFlow.Node.emit/2`), following the
  protocol named: one server-sent event, one line of JSON, or one line of
  text. See [specs/150](specs/150_streaming.md).

  `body_file` takes a file reference (see `PurpleFlow.RunFiles`) and sends
  the file as the body, streamed from disk, with the reference's type as
  `content-type` unless `headers` sets one. `form` sends
  `multipart/form-data`: a field holding a file reference becomes a file
  part, streamed from disk; any other value is text (maps and lists as
  JSON). See [specs/260](specs/260_file_transport.md).
  """

  @behaviour PurpleFlow.Node

  alias PurpleFlow.{RunFiles, StreamParser}

  @protocols ~w(sse ndjson lines)

  @impl true
  def prepare(config, _node_dir, _root) do
    cond do
      Enum.count(~w(body body_file form), &Map.has_key?(config, &1)) > 1 ->
        {:error, "takes one of body, body_file, and form, not more"}

      bad_form?(config["form"]) ->
        {:error, "form must be a table of fields, not #{inspect(config["form"])}"}

      config["stream"] in [nil | @protocols] ->
        {:ok, config}

      true ->
        {:error, ~s(stream must be "sse", "ndjson", or "lines", not #{inspect(config["stream"])})}
    end
  end

  @impl true
  def execute(_input, config) do
    with {:ok, body, body_headers} <- body(config) do
      options =
        [
          method:
            config |> Map.get("method", "GET") |> String.downcase() |> String.to_existing_atom(),
          url: Map.fetch!(config, "url"),
          headers: headers(Map.get(config, "headers", %{}), body_headers),
          params: Map.get(config, "query", %{}),
          retry: false
        ] ++ body ++ Application.get_env(:purple_flow, :http_req_options, [])

      case config["stream"] do
        nil -> request(options)
        protocol -> stream(options, protocol)
      end
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

  # The body's Req options, and headers it needs unless `headers` sets them.
  defp body(%{"body_file" => ref}) do
    with {:ok, path} <- RunFiles.path(ref) do
      type = if is_map(ref), do: ref["type"], else: nil

      {:ok, [body: File.stream!(path, 65_536)],
       %{
         "content-type" => type || "application/octet-stream",
         "content-length" => Integer.to_string(File.stat!(path).size)
       }}
    end
  end

  defp body(%{"form" => form}) when is_map(form) do
    form
    |> Enum.reduce_while({:ok, []}, fn {name, value}, {:ok, fields} ->
      case form_field(value) do
        {:ok, field} -> {:cont, {:ok, [{name, field} | fields]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, fields} -> {:ok, [form_multipart: fields], %{}}
      error -> error
    end
  end

  defp body(%{"form" => form}),
    do: {:error, "form must be a table of fields, not #{inspect(form)}"}

  defp body(%{"body" => nil}), do: {:ok, [], %{}}
  defp body(%{"body" => body}) when is_map(body) or is_list(body), do: {:ok, [json: body], %{}}
  defp body(%{"body" => body}), do: {:ok, [body: to_string(body)], %{}}
  defp body(_config), do: {:ok, [], %{}}

  # A placeholder can only be checked once it's filled in.
  defp bad_form?(nil), do: false
  defp bad_form?("{{" <> _), do: false
  defp bad_form?(form), do: not is_map(form)

  defp form_field(value) do
    cond do
      RunFiles.ref?(value) ->
        with {:ok, path} <- RunFiles.path(value) do
          {:ok,
           {File.stream!(path, 65_536),
            filename: value["name"] || "file",
            content_type: value["type"] || "application/octet-stream"}}
        end

      is_binary(value) ->
        {:ok, value}

      is_map(value) or is_list(value) ->
        {:ok, Jason.encode!(value)}

      true ->
        {:ok, to_string(value)}
    end
  end

  # Header names are matched without case, so `Content-Type` in `headers`
  # wins over the body's own.
  defp headers(headers, defaults) do
    given = MapSet.new(headers, fn {name, _} -> String.downcase(to_string(name)) end)
    Map.merge(Map.reject(defaults, fn {name, _} -> name in given end), headers)
  end

  defp preview(body) when is_binary(body), do: String.slice(body, 0, 500)
  defp preview(body), do: body |> Jason.encode!() |> String.slice(0, 500)
end
