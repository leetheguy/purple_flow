# Holds its place long enough for the others to start, then hands back a little.
:timer.sleep(input["sleep_ms"])
%{"n" => input["n"], "done_at" => System.system_time(:millisecond)}
