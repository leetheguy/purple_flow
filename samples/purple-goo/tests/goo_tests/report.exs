# Sums up the results, failures first by case name.
results = input["items"]
failed = results |> Enum.reject(& &1["pass"]) |> Enum.sort_by(& &1["case"])

%{
  "passed" => length(results) - length(failed),
  "total" => length(results),
  "failed" => Enum.map(failed, &Map.take(&1, ["case", "detail"]))
}
