defmodule PurpleFlow.Nodes.OpenAIChat do
  @moduledoc """
  Calls an OpenAI-compatible chat completions API (OpenAI, OpenRouter, a
  local server…) with streaming on, and streams the answer straight back to
  the webhook caller in the same format, so a chat app pointed at the
  webhook sees an ordinary OpenAI stream.

      module = "PurpleFlow.Nodes.OpenAIChat"

      [config]
      url = "https://openrouter.ai/api/v1/chat/completions"
      headers = { authorization = "Bearer {{ creds.OPENROUTER_API_KEY }}" }
      body = "{{ steps.build.output }}"   # model, messages, …; `stream` is set for you
      respond = true                      # default: stream to the waiting caller

  While the answer arrives, each server-sent event is passed on to the
  caller as it came (`data: {...}`), ending with `data: [DONE]`, and the
  caller's connection closes. It works like a Respond step: only with
  `respond = "result"` (the default), and only if nothing has answered yet.
  With `respond = false`, or nobody waiting, it just reads the stream.

  Either way the output, once the answer is complete, is the whole message:
  `{"content", "reasoning", "tool_calls", "finish_reason", "model", "id",
  "usage"}`, so the steps after it (saving the conversation, say) run after
  the caller already has the answer.

  A non-2xx response is an error, and the caller gets that status and body.
  An `error` the provider sends mid-stream is passed on, then fails the step.
  See `specs/240_openai_chat.md`.
  """

  @behaviour PurpleFlow.Node

  alias PurpleFlow.{Node, StreamParser}

  @headers %{"content-type" => "text/event-stream; charset=utf-8", "cache-control" => "no-cache"}

  @impl true
  def prepare(config, _node_dir, _root) do
    cond do
      not is_binary(config["url"]) -> {:error, "OpenAI Chat needs a url"}
      not Map.has_key?(config, "body") -> {:error, "OpenAI Chat needs a body"}
      config["respond"] not in [nil, true, false] -> {:error, "respond must be true or false"}
      true -> {:ok, config}
    end
  end

  @impl true
  def execute(_input, config) do
    with {:ok, body} <- body(config["body"]) do
      state = %{
        respond?: Map.get(config, "respond", true),
        sink: nil,
        parser: StreamParser.new(),
        done?: false,
        message: %{"content" => "", "reasoning" => nil, "tool_calls" => %{}},
        error: nil,
        failure: ""
      }

      options =
        [
          method: :post,
          url: config["url"],
          headers: Map.get(config, "headers", %{}),
          json: Map.put(body, "stream", true),
          retry: false,
          compressed: false,
          into: &receive_chunk/2
        ] ++ Application.get_env(:purple_flow, :openai_chat_req_options, [])

      Process.put(__MODULE__, state)
      result = Req.request(options)
      finish(result, Process.delete(__MODULE__))
    end
  end

  defp body(body) when is_map(body), do: {:ok, body}
  defp body(other), do: {:error, "OpenAI Chat body must be a table, not #{inspect(other)}"}

  # Each piece of the response as it arrives. The state lives in the process
  # dictionary because Req's `into` only carries the request and response.
  defp receive_chunk({:data, data}, {req, resp}) do
    state = Process.get(__MODULE__)

    state =
      if resp.status in 200..299,
        do: stream(data, state),
        else: %{state | failure: state.failure <> data}

    Process.put(__MODULE__, state)
    {:cont, {req, resp}}
  end

  defp stream(data, state) do
    {events, parser} = StreamParser.parse("sse", state.parser, data)
    state = start(%{state | parser: parser})
    Enum.reduce(events, state, &event/2)
  end

  # The caller is taken at the first sign of a successful answer.
  defp start(%{respond?: true, sink: nil} = state) do
    case Node.respond_stream(200, @headers) do
      {:ok, sink} -> %{state | sink: sink}
      :none -> %{state | respond?: false}
    end
  end

  defp start(state), do: state

  defp event(%{"data" => "[DONE]"}, state) do
    relay(state, "data: [DONE]\n\n")
    %{state | done?: true}
  end

  defp event(%{"data" => data} = event, state) do
    text = if is_binary(data), do: data, else: Jason.encode!(data)
    name = if event["event"] in [nil, "message"], do: "", else: "event: #{event["event"]}\n"
    relay(state, [name, "data: ", text, "\n\n"])
    collect(data, state)
  end

  defp relay(%{sink: nil}, _text), do: :ok
  defp relay(%{sink: sink}, text), do: Node.respond_chunk(sink, text)

  # Builds up the whole message from the chunks.
  defp collect(%{"error" => error}, state), do: %{state | error: error}

  defp collect(%{} = chunk, state) do
    message =
      state.message
      |> put_present("id", chunk["id"])
      |> put_present("model", chunk["model"])
      |> put_present("usage", chunk["usage"])

    message =
      case chunk["choices"] do
        [choice | _] -> choice(message, choice)
        _ -> message
      end

    %{state | message: message}
  end

  defp collect(_other, state), do: state

  defp choice(message, choice) do
    delta = choice["delta"] || %{}
    reasoning = delta["reasoning"] || delta["reasoning_content"]

    message
    |> Map.update!("content", &(&1 <> (delta["content"] || "")))
    |> Map.put("reasoning", append(message["reasoning"], reasoning))
    |> Map.update!("tool_calls", &tool_calls(&1, delta["tool_calls"]))
    |> put_present("finish_reason", choice["finish_reason"])
  end

  defp append(so_far, nil), do: so_far
  defp append(nil, more), do: more
  defp append(so_far, more), do: so_far <> more

  # Tool calls arrive in pieces, keyed by `index`; names and arguments are
  # strings to join.
  defp tool_calls(calls, nil), do: calls

  defp tool_calls(calls, deltas) do
    Enum.reduce(deltas, calls, fn delta, calls ->
      Map.update(calls, delta["index"] || 0, without_index(delta), fn call ->
        call
        |> put_present("id", delta["id"])
        |> put_present("type", delta["type"])
        |> Map.put("function", function(call["function"], delta["function"]))
      end)
    end)
  end

  defp without_index(delta), do: Map.delete(delta, "index")

  defp function(so_far, nil), do: so_far

  defp function(so_far, more) do
    so_far = so_far || %{}

    Enum.reduce(["name", "arguments"], so_far, fn key, acc ->
      case more[key] do
        nil -> acc
        text -> Map.put(acc, key, append(acc[key], text))
      end
    end)
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp finish({:ok, %Req.Response{status: status}}, state) when status in 200..299 do
    state = start(state)
    if not state.done?, do: relay(state, "data: [DONE]\n\n")
    close(state)

    case state.error do
      nil -> {:ok, output(state.message)}
      error -> {:error, "the provider sent an error: #{error_message(error)}"}
    end
  end

  defp finish({:ok, %Req.Response{status: status}}, state) do
    body =
      case Jason.decode(state.failure) do
        {:ok, decoded} -> decoded
        {:error, _} -> state.failure
      end

    if state.respond?,
      do: Node.respond(%{"status" => status, "headers" => %{}, "body" => body})

    {:error, "HTTP #{status}: #{String.slice(state.failure, 0, 500)}"}
  end

  defp finish({:error, error}, state) do
    message = "request failed: #{Exception.message(error)}"

    cond do
      state.sink ->
        relay(state, ["data: ", Jason.encode!(%{"error" => %{"message" => message}}), "\n\n"])
        close(state)

      state.respond? ->
        Node.respond(%{
          "status" => 502,
          "headers" => %{},
          "body" => %{"error" => %{"message" => message}}
        })

      true ->
        :ok
    end

    {:error, message}
  end

  defp close(%{sink: nil}), do: :ok
  defp close(%{sink: sink}), do: Node.respond_done(sink)

  defp output(message) do
    calls = message["tool_calls"] |> Enum.sort() |> Enum.map(fn {_index, call} -> call end)

    message
    |> Map.put("tool_calls", if(calls == [], do: nil, else: calls))
    |> Map.put_new("finish_reason", nil)
    |> Map.put_new("model", nil)
    |> Map.put_new("id", nil)
    |> Map.put_new("usage", nil)
  end

  defp error_message(%{"message" => message}), do: message
  defp error_message(error), do: inspect(error)
end
