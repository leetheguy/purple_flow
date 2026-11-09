# The place comes from the split item that led here. A run that ends with
# no output means a step in it failed: that's an error, never an empty value.
call = steps["split"]["output"]["call"]

case input do
  nil -> %{"index" => call["index"], "error" => "workflow #{call["workflow"]} returned nothing"}
  output -> %{"index" => call["index"], "output" => output}
end
