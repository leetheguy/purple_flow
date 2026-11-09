# Echoes the request back as the answer's content, as an OpenAI stream, or
# makes a tool call when the last user message asks for one:
#   "tools:N"       calls run_workflow (goo_test_tool) until N tool results
#                   are in the history, then echoes
#   "tools:fail"    one run_workflow call that fails
#   "client:NAME"   calls the client's tool NAME once, if it's offered
# A tool that isn't offered is never called.
request = input["body"]
messages = request["messages"] || []
offered = for tool <- request["tools"] || [], do: tool["function"]["name"]
results = Enum.count(messages, &(&1["role"] == "tool"))

last_user =
  messages |> Enum.filter(&(&1["role"] == "user")) |> List.last() |> Kernel.||(%{})

wanted =
  case last_user["content"] do
    "client:" <> name ->
      if results == 0, do: {name, %{}}

    "tools:fail" ->
      if results == 0, do: {"run_workflow", %{"fail" => true}}

    "tools:" <> n ->
      if results < String.to_integer(n), do: {"run_workflow", %{"n" => results + 1}}

    _ ->
      nil
  end

stream = fn delta, finish ->
  chunk = %{
    "id" => "fake",
    "model" => request["model"],
    "choices" => [%{"index" => 0, "delta" => delta, "finish_reason" => finish}]
  }

  "data: " <> Jason.encode!(chunk) <> "\n\ndata: [DONE]\n\n"
end

cond do
  request["model"] == "boom" ->
    {:error, "the fake provider was told to fail"}

  match?({name, _} when is_binary(name), wanted) and elem(wanted, 0) in offered ->
    {name, args} = wanted

    args =
      if name == "run_workflow", do: %{"name" => "goo_test_tool", "params" => args}, else: args

    call = %{
      "index" => 0,
      "id" => "call_#{results + 1}",
      "type" => "function",
      "function" => %{"name" => name, "arguments" => Jason.encode!(args)}
    }

    stream.(%{"role" => "assistant", "tool_calls" => [call]}, "tool_calls")

  true ->
    seen = %{
      "model" => request["model"],
      "has_metadata" => Map.has_key?(request, "metadata"),
      "messages" => Enum.map(messages, &[&1["role"], &1["content"]])
    }

    seen = if offered == [], do: seen, else: Map.put(seen, "tools", offered)

    # Whether any tool's description tells the agent it can run goo.
    hint? =
      Enum.any?(request["tools"] || [], &((&1["function"]["description"] || "") =~ "\"goo\""))

    seen = if hint?, do: Map.put(seen, "goo_hint", true), else: seen

    # ?which=name in the URL says which provider URL a monad used.
    which = input["query"]["which"]
    seen = if which, do: Map.put(seen, "which", which), else: seen

    stream.(%{"role" => "assistant", "content" => Jason.encode!(seen)}, "stop")
end
