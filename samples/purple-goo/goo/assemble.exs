# Messages are [personas, instruction, history, data, thoughts]. Everything
# injected that must not go back up is listed in "injected", so the
# denormalizer can remove it by exact match. Data stays.
%{"request" => request, "meta" => meta} = steps["opening"]["output"]

instruction =
  "Messages that begin \"Thought\" are your own thoughts and feelings. " <>
    "Let them shape your answer, but never quote them or speak of them."

system = fn text -> %{"role" => "system", "content" => text} end

# A failed data workflow fails the monad; a failed child is a thought.
data =
  for result <- steps["data"]["output"]["results"] do
    case result do
      %{"error" => error} -> raise "a data workflow failed: " <> error
      %{"output" => %{"role" => _} = message} -> message
      %{"output" => text} when is_binary(text) -> system.(text)
      %{"output" => other} -> system.(Jason.encode!(other))
    end
  end

thoughts =
  for result <- input["results"] do
    case result do
      %{"error" => error} -> "Thought (a monad failed): " <> error
      %{"output" => answer} -> "Thought: " <> (answer["content"] || "")
    end
  end

top = meta["personas"] ++ if(thoughts == [], do: [], else: [instruction])

messages =
  Enum.map(top, system) ++ (request["messages"] || []) ++ data ++ Enum.map(thoughts, system)

%{
  "url" => meta["provider_url"] || "https://openrouter.ai/api/v1/chat/completions",
  "body" => Map.put(request, "messages", messages),
  "injected" => top ++ thoughts
}
