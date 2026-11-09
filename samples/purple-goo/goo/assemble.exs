# Messages are [personas, skill sheet, instruction, history, data,
# thoughts]. Everything injected that must not go back up is listed in
# "injected", so the denormalizer can remove it by exact match. Data stays.
# The input is the prompts step's output.
%{"request" => request, "meta" => meta} = steps["opening"]["output"]
%{"instruction" => instruction, "skill" => skill} = input

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
  for result <- steps["monads"]["output"]["results"] do
    case result do
      %{"error" => error} -> "Thought (a monad failed): " <> error
      %{"output" => answer} -> "Thought: " <> (answer["content"] || "")
    end
  end

# The skill sheet is on unless _meta.swarm_skill is false (spec 020).
top =
  meta["personas"] ++
    if(meta["_meta"]["swarm_skill"] == false, do: [], else: [skill]) ++
    if(thoughts == [], do: [], else: [instruction])

messages =
  Enum.map(top, system) ++ (request["messages"] || []) ++ data ++ Enum.map(thoughts, system)

%{
  "url" => meta["_meta"]["provider_url"] || "https://openrouter.ai/api/v1/chat/completions",
  "body" => Map.put(request, "messages", messages),
  "injected" => top ++ thoughts
}
