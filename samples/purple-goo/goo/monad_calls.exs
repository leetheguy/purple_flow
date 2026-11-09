# A child gets the request (history, tools, ...) and only its own subtree,
# never this monad's metadata or its siblings'. Its model is the subtree's,
# else this request's.
request = steps["opening"]["output"]["request"]

calls =
  for subtree <- steps["opening"]["output"]["meta"]["monads"] do
    child =
      Map.merge(request, %{"model" => subtree["model"] || request["model"], "metadata" => subtree})

    %{"workflow" => "goo", "input" => child}
  end

%{"body" => %{"calls" => calls}}
