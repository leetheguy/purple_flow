# Both paths are named routes: a step without `when` takes every route.
# Each item is the called workflow's input: its body, like a webhook's, and
# "call" saying which workflow and where it sits in the list.
case input["body"]["calls"] || [] do
  [] ->
    {:ok, %{"items" => []}, "empty"}

  calls ->
    items =
      for {call, index} <- Enum.with_index(calls) do
        %{"body" => call["input"], "call" => %{"workflow" => call["workflow"], "index" => index}}
      end

    {:ok, items, "calls"}
end
