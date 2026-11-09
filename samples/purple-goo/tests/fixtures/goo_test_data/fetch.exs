# A data workflow gets {"frame", "data"} as its body.
data = input["body"]["data"] || %{}

case data["kind"] do
  "text" -> "fact: " <> data["x"]
  "message" -> %{"role" => "user", "content" => "from data"}
  "map" -> %{"n" => 1}
  "boom" -> {:error, "the data workflow was told to fail"}
  nil -> "plain"
end
