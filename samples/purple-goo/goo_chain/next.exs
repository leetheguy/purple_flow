# Both paths are named routes: a step without `when` takes every route.
# A call is {"workflow", "data"}, or just a workflow name.
%{"frame" => frame} = body = input["body"]

case body["calls"] || [] do
  [] ->
    {:ok, frame, "done"}

  [call | rest] ->
    call = if is_binary(call), do: %{"workflow" => call}, else: call

    {:ok,
     %{
       "body" => %{"frame" => frame, "data" => call["data"]},
       "call" => %{"workflow" => call["workflow"], "rest" => rest}
     }, "call"}
end
