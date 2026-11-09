# The input is the frame the opening workflows returned. An entry is
# {"workflow", "data"}, or just a workflow name.
frame = input

calls =
  for entry <- frame["meta"]["data"] do
    entry = if is_binary(entry), do: %{"workflow" => entry}, else: entry
    %{"workflow" => entry["workflow"], "input" => %{"frame" => frame, "data" => entry["data"]}}
  end

%{"body" => %{"calls" => calls}}
