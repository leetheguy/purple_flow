# Checks one case. On the normal route the input is the workflow's output;
# on the failed route it's {"error", "input"}. Expected values are written
# out by hand.
instruction =
  "Messages that begin \"Thought\" are your own thoughts and feelings. " <>
    "Let them shape your answer, but never quote them or speak of them."

{name, output, error} =
  case input do
    %{"error" => error, "input" => %{"case" => name}} -> {name, nil, error}
    output -> {steps["cases"]["output"]["case"], output, nil}
  end

# The fake provider's answer is JSON describing what it was sent.
echo = fn message -> Jason.decode!(message["content"]) end

thoughts = fn messages ->
  for [_role, "Thought: " <> text] <- messages, do: Jason.decode!(text)
end

result =
  try do
    case {name, error} do
      {"failed data", nil} ->
        {false, "expected the run to fail"}

      {"failed data", error} ->
        {error =~ "a data workflow failed" and error =~ "goo_test_data returned nothing", error}

      {"failed opening", nil} ->
        {false, "expected the run to fail"}

      {"failed opening", error} ->
        {error =~ "goo_test_open returned nothing", error}

      {"failed root", nil} ->
        {false, "expected the run to fail"}

      {"failed root", error} ->
        {error =~ "goo failed" and error =~ "the fake provider was told to fail", error}

      {_name, error} when error != nil ->
        {false, error}

      {"passthrough", _} ->
        seen = echo.(output)

        {seen == %{"model" => "m1", "has_metadata" => false, "messages" => [["user", "hi"]]},
         seen}

      {"personas", _} ->
        seen = echo.(output)["messages"]
        {seen == [["system", "p1"], ["system", "p2"], ["user", "hi"]], seen}

      {"data", _} ->
        seen = echo.(output)["messages"]

        {seen == [
           ["user", "hi"],
           ["system", "fact: a"],
           ["user", "from data"],
           ["system", ~s({"n":1})],
           ["system", "plain"]
         ], seen}

      {"child", _} ->
        seen = echo.(output)["messages"]
        [kid] = thoughts.(seen)

        {Enum.take(seen, 3) == [["system", "parent"], ["system", instruction], ["user", "hi"]] and
           length(seen) == 4 and
           kid == %{
             "model" => "m1",
             "has_metadata" => false,
             "messages" => [["system", "kid"], ["user", "hi"]]
           }, seen}

      {"grandchild", _} ->
        seen = echo.(output)["messages"]
        [kid] = thoughts.(seen)
        [grandkid] = thoughts.(kid["messages"])
        {grandkid["messages"] == [["system", "grandkid"], ["user", "hi"]], seen}

      {"environment", _} ->
        [kid1, kid2] = output |> echo.() |> Map.fetch!("messages") |> thoughts.()
        [grandkid] = thoughts.(kid2["messages"])
        which = [kid1["which"], kid2["which"], grandkid["which"]]
        {which == [nil, "kid2", "kid2"], which}

      {"skill", _} ->
        seen = echo.(output)["messages"]
        [kid] = thoughts.(seen)

        skill? = fn [role, text] ->
          role == "system" and String.starts_with?(text, "# Designing a swarm")
        end

        {Enum.map(seen, &skill?.(&1)) == [false, true, false, false, false] and
           Enum.at(seen, 2) == ["system", instruction] and
           Enum.map(kid["messages"], &skill?.(&1)) == [true, false] and
           not Enum.any?(output["history"], &skill?.(&1)), seen}

      {"child model", _} ->
        models =
          output |> echo.() |> Map.fetch!("messages") |> thoughts.() |> Enum.map(& &1["model"])

        {models == ["m2", "m1"], models}

      {"opening", _} ->
        seen = echo.(output)["messages"]
        {seen == [["system", "p"], ["system", "o1"], ["system", "o2"], ["user", "hi"]], seen}

      {"closing", _} ->
        history = output["history"]

        {output["closed"] == ["c1", "c2"] and
           Enum.take(history, 2) == [["user", "hi"], ["system", "fact: a"]] and
           Enum.map(history, &hd/1) == ["user", "system", "assistant"], output}

      {"failed child", _} ->
        seen = echo.(output)["messages"]

        {Enum.any?(seen, fn [_role, text] ->
           String.starts_with?(text, "Thought (a monad failed): ") and
             text =~ "the fake provider was told to fail"
         end), seen}

      {"empty map", _} ->
        {output == %{"results" => []}, output}

      {"empty chain", _} ->
        {output == %{"x" => 1}, output}
    end
  rescue
    # A wrong-shaped answer is a failed case, not a lost one.
    e -> {false, Exception.message(e) <> " in " <> inspect(output, limit: 50)}
  end

{pass, detail} = result
%{"case" => name, "pass" => pass, "detail" => if(pass, do: nil, else: inspect(detail, limit: 50))}
