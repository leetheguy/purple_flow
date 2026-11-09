# The frame is {"request", "meta"}: the chat request as the provider will
# get it, and this monad's metadata. Unknown metadata keys ride along.
body = input["body"]

meta =
  Map.merge(
    %{"personas" => [], "data" => [], "monads" => [], "opening" => [], "closing" => []},
    body["metadata"] || %{}
  )

frame = %{"request" => Map.delete(body, "metadata"), "meta" => meta}
%{"body" => %{"calls" => meta["opening"], "frame" => frame}}
