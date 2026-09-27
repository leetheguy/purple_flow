# Runs the "diamonds" workflow once and reports what it produced.
#   mix run samples/testing/harness/pf_diamonds.exs
# Needs samples/testing/diamonds in the workflows folder. See ../README.md.
import Ecto.Query

{:ok, _} = PurpleFlow.Workflows.fetch("diamonds")
id = PurpleFlow.Id.generate()
t0 = System.monotonic_time(:millisecond)
input = %{"body" => %{}, "query" => %{}, "headers" => %{}}
result = PurpleFlow.run_and_wait("diamonds", input, id: id)
elapsed = System.monotonic_time(:millisecond) - t0

uuid = Ecto.UUID.dump!(id)

counts =
  PurpleFlow.Repo.all(
    from s in "step_runs",
      where: s.run_id == ^uuid,
      group_by: s.status,
      select: {s.status, count(s.id)}
  )

IO.inspect(result, label: "result")
IO.puts("elapsed=#{elapsed}ms status=#{PurpleFlow.Runs.get(id).run.status}")
IO.inspect(counts, label: "step_runs by status")
