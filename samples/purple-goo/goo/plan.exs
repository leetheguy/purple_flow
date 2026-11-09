# The answer, from the agent or its tool chain, is the speaker's thought,
# after the speak note.
%{"kind" => kind, "message" => message} = input
assembled = steps["assemble"]["output"]

if steps["opening"]["output"]["role"] == "top" and kind != "client" do
  note = %{"role" => "system", "content" => steps["prompts"]["output"]["speak"]}
  thought = %{"role" => "system", "content" => "Thought: " <> (message["content"] || "")}
  speak = Map.update!(assembled["speak"], "messages", &(&1 ++ [note, thought]))
  {:ok, %{"url" => assembled["url"], "body" => speak}, "speak"}
else
  {:ok, message, "done"}
end
