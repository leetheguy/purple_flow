# Calls finish in any order; their numbers put them back.
results =
  input["items"]
  |> Enum.sort_by(& &1["index"])
  |> Enum.map(&Map.delete(&1, "index"))

%{"results" => results}
