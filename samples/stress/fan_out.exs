# One item per execution of the next step.
body = input["body"] || %{}
count = body["count"] || 10_000
sleep_ms = body["sleep_ms"] || 1_000

for n <- 1..count//1, do: %{"n" => n, "sleep_ms" => sleep_ms}
