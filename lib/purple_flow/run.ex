defmodule PurpleFlow.Run do
  @moduledoc """
  One process per workflow run. It decides what starts next, and that's all
  it does. The actual work happens in `PurpleFlow.StepTask`s.

  How it goes:

  1. Save the run, start every step with no `after`.
  2. Each time a step finishes (all of its items), start the steps that come
     after it.
  3. Nothing running and nothing left to start: save the output, stop.
  4. Any failure: save the error, stop. Nothing new starts.

  (A "GenServer" is Elixir's standard long-running process: it holds some
  state and handles messages one at a time.)
  """

  # `restart: :temporary` means a crashed run is never restarted. Restarting
  # would repeat its side effects (API calls, inserts).
  use GenServer, restart: :temporary

  alias PurpleFlow.{Runs, StepTask, Workflow}

  @max_items 10_000

  def start_link(args), do: GenServer.start_link(__MODULE__, args)

  @impl true
  def init(args) do
    state = %{
      id: args.id,
      workflow: args.workflow,
      trigger: args.trigger,
      input: args.input,
      # Latest output of each step that finished, by step name.
      outputs: %{},
      # Steps currently running (or queued), by instance number. A step can
      # start more than once (after parallel branches), so each start gets
      # its own instance.
      active: %{},
      next_instance: 0,
      failure: nil
    }

    {:ok, state, {:continue, :start}}
  end

  @impl true
  def handle_continue(:start, state) do
    # Subscribe before starting anything, so no "finished" message is missed.
    Phoenix.PubSub.subscribe(PurpleFlow.PubSub, PurpleFlow.topic(state.id))
    Runs.start_run(state.id, state.workflow.name, state.trigger, state.input)
    PurpleFlow.broadcast(state.id, {:run_started, state.id, state.workflow.name}, runs: true)

    state.workflow
    |> Workflow.first_steps()
    |> Enum.reduce(state, fn step, state -> start_step(state, step, state.input, nil) end)
    |> finish_or_continue()
  end

  @impl true
  def handle_info({:step_finished, _run_id, _step, item, result}, state) do
    case Map.fetch(state.active, result.instance) do
      {:ok, instance} ->
        state
        |> record(result.instance, instance, item, result)
        |> finish_or_continue()

      :error ->
        {:noreply, state}
    end
  end

  # Our own step_started / run_started broadcasts come back to us too. Ignore them.
  def handle_info(_message, state), do: {:noreply, state}

  # -- starting steps --

  # Starts a step with `input`. A list input (with `run = "each"`) means one
  # execution per item. `origins` says which earlier item each input item came from.
  defp start_step(%{failure: nil} = state, step, input, origins) do
    items =
      if step.run == :each and is_list(input) do
        origins = origins || List.duplicate(nil, length(input))

        Enum.zip([input, origins, 0..(length(input) - 1)//1])
        |> Enum.map(fn {value, from, i} -> %{item: i, input: value, from_item: from} end)
      else
        [%{item: nil, input: input, from_item: nil}]
      end

    instance = %{
      step: step,
      per_item?: step.run == :each and is_list(input),
      queue: items,
      total: length(items),
      running: 0,
      results: %{},
      steps: ancestor_outputs(state, step)
    }

    id = state.next_instance
    state = %{state | active: Map.put(state.active, id, instance), next_instance: id + 1}

    # An empty list means zero executions: the step is done right away.
    if instance.total == 0, do: complete(state, id), else: launch(state, id)
  end

  defp start_step(state, _step, _input, _origins), do: state

  # Starts queued executions, up to the step's concurrency limit.
  defp launch(state, id) do
    instance = state.active[id]
    slots = instance.step.concurrency - instance.running
    {now, later} = Enum.split(instance.queue, max(slots, 0))

    for item <- now do
      StepTask.start(%{
        run_id: state.id,
        step: instance.step,
        item: item.item,
        from_item: item.from_item,
        input: item.input,
        steps: instance.steps,
        instance: id
      })
    end

    instance = %{instance | queue: later, running: instance.running + length(now)}
    %{state | active: Map.put(state.active, id, instance)}
  end

  defp ancestor_outputs(state, step) do
    state.outputs
    |> Map.take(step.ancestors)
    |> Map.new(fn {name, output} -> {name, %{"output" => output}} end)
  end

  # -- finishing steps --

  defp record(state, id, instance, item, %{status: :ok} = result) do
    instance = %{
      instance
      | running: instance.running - 1,
        results: Map.put(instance.results, item, {result.output, result.route})
    }

    state = %{state | active: Map.put(state.active, id, instance)}

    cond do
      state.failure -> state
      instance.queue != [] -> launch(state, id)
      instance.running == 0 -> complete(state, id)
      true -> state
    end
  end

  defp record(state, _id, instance, item, result) do
    fail(state, instance.step.name, item, result.error["message"])
  end

  # All of a step's executions are done: save its output and start what's next.
  defp complete(state, id) do
    instance = state.active[id]
    step = instance.step
    state = %{state | active: Map.delete(state.active, id)}

    # Each entry is {value, which execution it came from, route}.
    entries =
      if instance.per_item? do
        for item <- 0..(instance.total - 1)//1,
            {output, route} = instance.results[item],
            value <- List.wrap(output),
            do: {value, item, route}
      else
        {output, route} = instance.results[nil]
        [{output, nil, route}]
      end

    output =
      if instance.per_item?,
        do: Enum.map(entries, &elem(&1, 0)),
        else: elem(hd(entries), 0)

    if is_list(output) and length(output) > @max_items do
      fail(state, step.name, nil, "output has more than #{@max_items} items")
    else
      state = %{state | outputs: Map.put(state.outputs, step.name, output)}

      state.workflow
      |> Workflow.next_steps(step.name)
      |> Enum.reduce(state, fn next, state ->
        start_next(state, next, instance.per_item?, entries, output)
      end)
    end
  end

  # No `when`: the next step gets the whole output.
  defp start_next(state, %{when: nil} = next, per_item?, entries, output) do
    origins = if per_item?, do: Enum.map(entries, &elem(&1, 1))
    start_step(state, next, output, origins)
  end

  # With `when`: only the outputs that took that route. None? It doesn't run.
  defp start_next(state, next, per_item?, entries, _output) do
    case Enum.filter(entries, fn {_, _, route} -> route == next.when end) do
      [] ->
        state

      matching when per_item? ->
        start_step(
          state,
          next,
          Enum.map(matching, &elem(&1, 0)),
          Enum.map(matching, &elem(&1, 1))
        )

      [{output, _, _}] ->
        start_step(state, next, output, nil)
    end
  end

  # -- ending the run --

  defp fail(state, step, item, message) do
    %{state | failure: %{"step" => step, "item" => item, "message" => message}}
  end

  defp finish_or_continue(%{failure: failure} = state) when failure != nil do
    Runs.finish_run(state.id, "failed", error: failure)
    PurpleFlow.broadcast(state.id, {:run_finished, state.id, "failed"}, runs: true)
    {:stop, :normal, state}
  end

  defp finish_or_continue(%{active: active} = state) when active == %{} do
    Runs.finish_run(state.id, "complete", output: run_output(state))
    PurpleFlow.broadcast(state.id, {:run_finished, state.id, "complete"}, runs: true)
    {:stop, :normal, state}
  end

  defp finish_or_continue(state), do: {:noreply, state}

  # The output of the last steps (the ones nothing comes after) that ran.
  defp run_output(state) do
    ran =
      for step <- Workflow.last_steps(state.workflow),
          Map.has_key?(state.outputs, step.name),
          do: step.name

    case ran do
      [] -> nil
      [one] -> state.outputs[one]
      many -> Map.take(state.outputs, many)
    end
  end
end
