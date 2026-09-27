# Runs the "stress" workflow once and samples the app's VM until it ends.
#   COUNT=10000 SLEEP_MS=1000 mix run samples/testing/harness/pf_stress.exs
# Needs samples/testing/stress in the workflows folder. See ../README.md.
count = String.to_integer(System.get_env("COUNT", "10000"))
sleep_ms = String.to_integer(System.get_env("SLEEP_MS", "1000"))
limit_ms = 15 * 60 * 1000

{:ok, _} = PurpleFlow.Workflows.fetch("stress")
id = PurpleFlow.Id.generate()
Phoenix.PubSub.subscribe(PurpleFlow.PubSub, PurpleFlow.topic(id))
t0 = System.monotonic_time(:millisecond)
input = %{"body" => %{"count" => count, "sleep_ms" => sleep_ms}, "query" => %{}, "headers" => %{}}
{:ok, ^id} = PurpleFlow.run("stress", input, id: id)
IO.puts("run #{id}: #{count} items, #{sleep_ms} ms each")

mb = fn -> Float.round(:erlang.memory(:total) / 1_048_576, 1) end

wait = fn wait, peak, last ->
  now = System.monotonic_time(:millisecond) - t0

  {peak, last} =
    if now - last >= 1000 do
      m = mb.()
      IO.puts("t=#{div(now, 1000)}s app=#{m}MB processes=#{:erlang.system_info(:process_count)}")
      {max(peak, m), now}
    else
      {peak, last}
    end

  receive do
    {:run_finished, ^id, status} -> {status, now, peak}
    _other -> wait.(wait, peak, last)
  after
    200 ->
      if now > limit_ms do
        PurpleFlow.kill(id)
        {"gave up", now, peak}
      else
        wait.(wait, peak, last)
      end
  end
end

{status, elapsed, peak} = wait.(wait, mb.(), -1000)
# Rows are saved every 250 ms; let the last batch land.
Process.sleep(500)

import Ecto.Query
uuid = Ecto.UUID.dump!(id)

counts =
  PurpleFlow.Repo.all(
    from s in "step_runs",
      where: s.run_id == ^uuid,
      group_by: [s.step, s.status],
      select: {s.step, s.status, count(s.id)}
  )

errors =
  PurpleFlow.Repo.all(
    from s in "step_runs",
      where: s.run_id == ^uuid and s.status != "ok",
      group_by: fragment("left(?::text, 160)", s.error),
      select: {fragment("left(?::text, 160)", s.error), count(s.id)},
      limit: 5
  )

IO.puts("\nstatus=#{status} elapsed=#{elapsed}ms peak_app=#{peak}MB")
IO.inspect(PurpleFlow.Runs.get(id).run.output, label: "output")
IO.inspect(counts, label: "step_runs")
IO.inspect(errors, label: "errors")
