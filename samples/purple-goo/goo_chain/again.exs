# A run that ends with no output means a step in it failed: fail loudly,
# naming it, rather than hand an empty frame on.
call = steps["next"]["output"]["call"]

case input do
  nil -> {:error, "workflow #{call["workflow"]} returned nothing"}
  frame -> %{"body" => %{"calls" => call["rest"], "frame" => frame}}
end
