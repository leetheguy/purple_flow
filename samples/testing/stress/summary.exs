items = input["items"]
times = Enum.map(items, & &1["done_at"])

%{
  "count" => length(items),
  "unique" => items |> Enum.map(& &1["n"]) |> Enum.uniq() |> length(),
  "first_done_to_last_done_ms" => Enum.max(times) - Enum.min(times)
}
