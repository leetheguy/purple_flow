# A closing workflow gets {"frame", "data"} and returns the new frame.
%{"frame" => frame, "data" => data} = input["body"]

update_in(frame, ["response"], fn response ->
  response
  |> Map.put("closed", (response["closed"] || []) ++ [data["tag"]])
  |> Map.put("history", Enum.map(frame["messages"], &[&1["role"], &1["content"]]))
end)
