# Tool calls arrive as a list, in order. A run_workflow call with bad arguments, or a call to a tool that isn't
# run_workflow, gets an error as its result instead of running.
role = steps["opening"]["output"]["role"]
client_tools = steps["assemble"]["output"]["client_tools"]

calls = input["tool_calls"] || []

names = Enum.map(calls, & &1["function"]["name"])

args = fn call ->
  case Jason.decode(call["function"]["arguments"] || "{}") do
    {:ok, %{"name" => name} = args} when is_binary(name) and name != "" -> {:ok, args}
    _ -> :error
  end
end

cond do
  calls == [] ->
    {:ok, %{"kind" => "answer", "message" => input}, "answer"}

  role == "top" and Enum.all?(names, &(&1 in client_tools)) ->
    {:ok, %{"kind" => "client", "message" => input}, "client"}

  true ->
    {plan, runs} =
      Enum.map_reduce(calls, [], fn call, runs ->
        case {call["function"]["name"], args.(call)} do
          {"run_workflow", {:ok, args}} ->
            run = %{"workflow" => args["name"], "input" => args["params"] || %{}}
            {%{"id" => call["id"], "index" => length(runs)}, runs ++ [run]}

          {"run_workflow", :error} ->
            {%{"id" => call["id"], "error" => "run_workflow needs a workflow name"}, runs}

          {name, _} ->
            {%{"id" => call["id"], "error" => "#{name} can't be run here; call it on its own"},
             runs}
        end
      end)

    assistant = %{
      "role" => "assistant",
      "content" => input["content"] || "",
      "tool_calls" => calls
    }

    {:ok, %{"body" => %{"calls" => runs}, "assistant" => assistant, "plan" => plan}, "tools"}
end
