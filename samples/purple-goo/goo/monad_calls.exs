# A child gets the request (history, tools, ...) and only its own subtree,
# never this monad's personas, data, or children, or its siblings'. Its
# model is the subtree's, else this request's. The one thing that cascades
# is _meta, the environment (provider_url, counters): this monad's, with the
# child's own _meta keys on top.
%{"request" => request, "meta" => meta} = steps["opening"]["output"]

calls =
  for subtree <- meta["monads"] do
    subtree = Map.put(subtree, "_meta", Map.merge(meta["_meta"], subtree["_meta"] || %{}))

    child =
      Map.merge(request, %{"model" => subtree["model"] || request["model"], "metadata" => subtree})

    %{"workflow" => "goo", "input" => child}
  end

%{"body" => %{"calls" => calls}}
