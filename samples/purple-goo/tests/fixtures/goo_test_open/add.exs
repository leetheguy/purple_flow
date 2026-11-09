# An opening workflow gets {"frame", "data"} and returns the new frame.
%{"frame" => frame, "data" => data} = input["body"]

if data["fail"], do: raise("the opening workflow was told to fail")

update_in(frame, ["meta", "personas"], &(&1 ++ [data["persona"]]))
