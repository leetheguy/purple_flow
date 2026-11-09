# Echoes the request back as the answer's content, as an OpenAI stream.
request = input["body"]

if request["model"] == "boom" do
  {:error, "the fake provider was told to fail"}
else
  content =
    Jason.encode!(%{
      "model" => request["model"],
      "has_metadata" => Map.has_key?(request, "metadata"),
      "messages" => Enum.map(request["messages"] || [], &[&1["role"], &1["content"]])
    })

  chunk = %{
    "id" => "fake",
    "model" => request["model"],
    "choices" => [
      %{
        "index" => 0,
        "delta" => %{"role" => "assistant", "content" => content},
        "finish_reason" => "stop"
      }
    ]
  }

  "data: " <> Jason.encode!(chunk) <> "\n\ndata: [DONE]\n\n"
end
