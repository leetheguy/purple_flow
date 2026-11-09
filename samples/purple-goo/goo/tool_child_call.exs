# One tool message per call, in order. Text results go as they are,
# anything else as JSON; an error is a result too, so the agent can decide.
# The tool child gets the history as this agent saw it and only _meta.
%{"assistant" => assistant, "plan" => plan} = steps["decide"]["output"]
results = input["results"]
assembled = steps["assemble"]["output"]

content = fn
  %{"output" => text} when is_binary(text) -> text
  %{"output" => other} -> Jason.encode!(other)
  %{"error" => error} -> Jason.encode!(%{"error" => error})
end

replies =
  for step <- plan do
    result =
      if step["error"], do: %{"error" => step["error"]}, else: Enum.at(results, step["index"])

    %{"role" => "tool", "tool_call_id" => step["id"], "content" => content.(result)}
  end

child =
  assembled["body"]
  |> Map.drop(["tools", "tool_choice", "parallel_tool_calls"])
  |> Map.merge(%{
    "messages" => assembled["body"]["messages"] ++ [assistant | replies],
    "metadata" => %{"_meta" => steps["opening"]["output"]["meta"]["_meta"]},
    "goo_role" => "tool"
  })

%{"body" => child}
