# Removal is by exact content, never by position, which breaks as soon as
# more than one prompt is injected. The frame gains "messages" (the history
# plus the answer) and "response" (the AI's message).
assembled = steps["assemble"]["output"]
injected = MapSet.new(assembled["injected"])

calls = Map.values(input["tool_calls"] || %{})
reply = %{"role" => "assistant", "content" => input["content"]}
reply = if calls == [], do: reply, else: Map.put(reply, "tool_calls", calls)

messages =
  (assembled["body"]["messages"] ++ [reply])
  |> Enum.reject(&(&1["role"] == "system" and MapSet.member?(injected, &1["content"])))

frame = Map.merge(steps["opening"]["output"], %{"messages" => messages, "response" => input})
%{"body" => %{"calls" => frame["meta"]["closing"], "frame" => frame}}
