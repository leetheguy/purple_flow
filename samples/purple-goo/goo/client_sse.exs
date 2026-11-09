# The chat app runs its own tools: hand it the call as the provider made it.
message = input["message"]

calls =
  (message["tool_calls"] || [])
  |> Enum.with_index()
  |> Enum.map(fn {call, index} -> Map.put(call, "index", index) end)

chunk = %{
  "id" => message["id"],
  "object" => "chat.completion.chunk",
  "model" => message["model"],
  "choices" => [
    %{
      "index" => 0,
      "delta" => %{"role" => "assistant", "content" => message["content"], "tool_calls" => calls},
      "finish_reason" => "tool_calls"
    }
  ]
}

Map.put(input, "sse", "data: " <> Jason.encode!(chunk) <> "\n\ndata: [DONE]\n\n")
