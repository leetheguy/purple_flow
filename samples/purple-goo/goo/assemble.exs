# Messages are [personas, skill sheet, instruction, history, data,
# thoughts]. Everything injected that must not go back up is listed in
# "injected", so the denormalizer can remove it by exact match. Data stays.
# The input is the prompts step's output.
#
# Two bodies come out (spec 030): "body" for the agent's think call, with
# the tools, and "speak" for the top monad's last call, which always has
# the instruction (its answer arrives as a thought) and no tools. A tool
# child injects nothing: its history already holds its parent's prompts.
%{"request" => request, "meta" => meta, "role" => role} = steps["opening"]["output"]
%{"instruction" => instruction, "skill" => skill, "tool" => tool} = input
swarm? = meta["_meta"]["swarm_skill"] == true

# The tool mentions goo only when the monad may build swarms (spec 020 log).
tool =
  if swarm?,
    do: update_in(tool, ["function", "description"], &(&1 <> input["swarm_hint"])),
    else: tool

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

# The skill sheet is off unless _meta.swarm_skill is true (spec 020 log).
personas =
  if role == "tool",
    do: [],
    else: meta["personas"] ++ if(swarm?, do: [skill], else: [])

top = personas ++ if(thoughts == [], do: [], else: [instruction])
rest = (request["messages"] || []) ++ data ++ Enum.map(thoughts, system)

# The client's tools (only the top monad has any), then run_workflow.
client = Enum.reject(request["tools"] || [], &(&1["function"]["name"] == "run_workflow"))
tools = client ++ if(meta["_meta"]["run_workflow"] == false, do: [], else: [tool])
plain = Map.drop(request, ["tools", "tool_choice", "parallel_tool_calls"])
think = if tools == [], do: plain, else: Map.put(request, "tools", tools)

%{
  "url" => meta["_meta"]["provider_url"] || "https://openrouter.ai/api/v1/chat/completions",
  "body" => Map.put(think, "messages", Enum.map(top, system) ++ rest),
  "speak" => Map.put(plain, "messages", Enum.map(personas ++ [instruction], system) ++ rest),
  "client_tools" => Enum.map(client, & &1["function"]["name"]),
  "injected" => top ++ thoughts ++ [instruction]
}
