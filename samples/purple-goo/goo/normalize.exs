# The frame is {"request", "meta", "role"}: the chat request as the
# provider will get it, this monad's metadata, and its role (spec 030):
# "top" (anyone calling from outside), "monad" (a child in the tree), or
# "tool" (a tool child). Unknown metadata keys ride along.
body = input["body"]

meta =
  Map.merge(
    %{
      "personas" => [],
      "data" => [],
      "monads" => [],
      "opening" => [],
      "closing" => [],
      "_meta" => %{}
    },
    body["metadata"] || %{}
  )

frame = %{
  "request" => Map.drop(body, ["metadata", "goo_role"]),
  "meta" => meta,
  "role" => body["goo_role"] || "top"
}

%{"body" => %{"calls" => meta["opening"], "frame" => frame}}
