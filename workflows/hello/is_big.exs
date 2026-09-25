# Runs once per number. Sends big numbers one way, small ones the other.
if input > 10 do
  {:ok, input, "big"}
else
  {:ok, input, "small"}
end
