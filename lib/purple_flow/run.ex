defmodule PurpleFlow.Run do
  @moduledoc """
  One process per workflow run. It holds a queue in front of every step,
  starts executions from those queues, hears their results, and sends what
  they produced on to the next steps' queues right away. Nothing waits for
  a whole step to finish. See `specs/120_flow.md`.

  How it goes:

  1. Save the run. The trigger's input goes into the first steps' queues
     (a list splits into items).
  2. Each step starts one execution per item from its queue, within its
     `concurrency` and `delay`, unless a full step after it holds it back.
  3. An execution finishes: its items go into the next steps' queues. A
     failure goes down the `failed` route, or ends the run (`on_fail`).
  4. Nothing queued, running, or batched anywhere: save the output, stop.

  Rows are saved in batches, at most every 250 ms, and a `run_progress`
  message goes out with each save.

  (A "GenServer" is Elixir's standard long-running process: it holds some
  state and handles messages one at a time.)
  """

  # `restart: :temporary` means a crashed run is never restarted. Restarting
  # would repeat its side effects (API calls, inserts).
  use GenServer, restart: :temporary

  require Logger

  alias PurpleFlow.{Runs, StepTask, Workflow}

  @flush_ms 250

  def start_link(args), do: GenServer.start_link(__MODULE__, args, name: via(args.id))

  defp via(id), do: {:via, Registry, {PurpleFlow.RunRegistry, id}}

  @doc "Stops a running run now. See `PurpleFlow.kill/1`."
  def kill(id) do
    GenServer.call(via(id), :kill, :infinity)
  catch
    :exit, _ -> {:error, "run #{id} isn't running"}
  end

  @impl true
  def init(args) do
    workflow = args.workflow
    names = Enum.map(workflow.steps, & &1.name)
    per_step = fn value -> Map.new(names, &{&1, value}) end

    state = %{
      id: args.id,
      workflow: workflow,
      trigger: args.trigger,
      input: args.input,
      # Gets {:run_item, id, step, item} for every item a last step produces,
      # and {:run_finished, id, status} at the end.
      stream_to: Map.get(args, :stream_to),
      # A webhook caller waiting for this run, until a Respond step answers
      # it: gets {:run_respond, id, reply}. See `PurpleFlow.Node.respond/1`.
      respond_to: Map.get(args, :respond_to),
      steps: Map.new(workflow.steps, &{&1.name, &1}),
      order: names,
      next: Map.new(names, &{&1, Workflow.next_steps(workflow, &1)}),
      last: MapSet.new(Workflow.last_steps(workflow), & &1.name),
      queues: per_step.(:queue.new()),
      # Batch steps only: items gathered so far (newest first), and the
      # token of the `wait` timer, if one is set.
      batches:
        for(
          step <- workflow.steps,
          Workflow.batch?(step),
          into: %{},
          do: {step.name, new_batch()}
        ),
      running: per_step.(0),
      # How many executions each step has started: the next one's number.
      started: per_step.(0),
      last_start: %{},
      delay_timers: MapSet.new(),
      counts: per_step.(%{ok: 0, failed: 0, overflow: 0}),
      # Running executions, by task ref, and task pid -> ref (for emit).
      execs: %{},
      pids: %{},
      # emit calls held back until there's room: {from, step name}.
      held: [],
      # Last steps' successful executions: [{number, output, items}].
      results: %{},
      rows: [],
      flush_timer: nil,
      # nil while running normally; {status, error} once it's ending.
      ending: nil,
      finished: false
    }

    {:ok, state, {:continue, :start}}
  end

  @impl true
  def handle_continue(:start, state) do
    Runs.start_run(state.id, state.workflow.name, state.trigger, state.input)
    PurpleFlow.broadcast(state.id, {:run_started, state.id, state.workflow.name}, runs: true)

    state.workflow
    |> Workflow.first_steps()
    |> Enum.reduce(state, fn step, state ->
      Enum.reduce(split(state.input), state, fn item, state ->
        enqueue(state, step, %{value: item, steps: %{}, from: nil})
      end)
    end)
    |> continue()
  end

  # -- messages --

  @impl true
  def handle_call({:emit, pid, value, route}, from, state) do
    with nil <- state.ending,
         {:ok, ref} <- Map.fetch(state.pids, pid) do
      exec = state.execs[ref]
      step = state.steps[exec.step]
      items = split(value)
      exec = %{exec | emitted: Enum.reverse(items, exec.emitted)}
      state = put_in(state.execs[ref], exec)
      state = produced(state, step, exec.no, exec.lineage, Enum.map(items, &{&1, route}))

      if held_back?(state, step) do
        {:noreply, advance(%{state | held: [{from, step.name} | state.held]})}
      else
        {:reply, :ok, advance(state)}
      end
    else
      # Ending, or an execution the run no longer knows: the item goes nowhere.
      _ -> {:reply, :ok, state}
    end
  end

  # Only the first answer goes to the caller; after it, nobody is waiting.
  def handle_call({:respond, _reply}, _from, %{respond_to: nil} = state),
    do: {:reply, :none, state}

  def handle_call({:respond, reply}, _from, state) do
    send(state.respond_to, {:run_respond, state.id, reply})
    {:reply, :ok, %{state | respond_to: nil}}
  end

  def handle_call(:kill, _from, state) do
    # Ending first, so what the stopped executions leave behind goes nowhere.
    state = stop_everything(state, {"killed", nil})

    state =
      Enum.reduce(state.execs, state, fn {ref, exec}, state ->
        Task.shutdown(exec.task, :brutal_kill)
        failed(state, ref, :killed, "killed")
      end)

    {:stop, :normal, state} = finish(state)
    {:stop, :normal, :ok, state}
  end

  @impl true
  def handle_info({ref, result}, state) when is_map_key(state.execs, ref) do
    Process.demonitor(ref, [:flush])
    state |> execution_done(ref, result) |> continue()
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state)
      when is_map_key(state.execs, ref) do
    state
    |> failed(ref, :error, "node crashed: #{Exception.format_exit(reason)}")
    |> continue()
  end

  def handle_info({:timeout, ref}, state) when is_map_key(state.execs, ref) do
    exec = state.execs[ref]

    case Task.shutdown(exec.task, :brutal_kill) do
      {:ok, result} ->
        state |> execution_done(ref, result) |> continue()

      _ ->
        seconds = state.steps[exec.step].timeout / 1000

        state
        |> failed(ref, :timed_out, "timed out after #{format_seconds(seconds)}s")
        |> continue()
    end
  end

  def handle_info({:delay_done, name}, state) do
    continue(%{state | delay_timers: MapSet.delete(state.delay_timers, name)})
  end

  def handle_info({:batch_wait, name, token}, state) do
    case state.batches[name] do
      %{token: ^token} -> state |> flush_batch(state.steps[name]) |> continue()
      _ -> {:noreply, state}
    end
  end

  def handle_info(:flush, state) do
    {:noreply, %{save_rows(state) | flush_timer: nil}}
  end

  # A timeout or an answer for an execution that already finished.
  def handle_info(_message, state), do: {:noreply, state}

  # If the run process itself crashes (a bug), close its record.
  @impl true
  def terminate(reason, %{finished: false} = state) when reason != :normal do
    save_rows(state)
    message = "the run crashed: #{Exception.format_exit(reason)}"
    Runs.finish_run(state.id, "failed", error: %{"message" => message})
    announce_finished(state, "failed")
  rescue
    error -> Logger.error("couldn't close crashed run #{state.id}: #{Exception.message(error)}")
  end

  def terminate(_reason, _state), do: :ok

  # -- items --

  # A list splits into items. Anything else is one item.
  defp split(list) when is_list(list), do: list
  defp split(value), do: [value]

  # Items an execution of `step` produced, each with its route: into the
  # queues of the steps after it that take that route.
  defp produced(state, step, number, lineage, items) do
    Enum.reduce(items, state, fn {value, route}, state ->
      if step.name in state.last and route not in ["failed", "overflow"] and state.stream_to,
        do: send(state.stream_to, {:run_item, state.id, step.name, value})

      entry = %{
        value: value,
        steps: Map.put(lineage, step.name, %{"output" => value}),
        from: number
      }

      state.next[step.name]
      |> Enum.filter(&takes_route?(&1, route))
      |> Enum.reduce(state, &enqueue(&2, &1, entry))
    end)
  end

  defp takes_route?(%{when: nil}, route), do: route not in ["failed", "overflow"]
  defp takes_route?(%{when: wanted}, route), do: wanted == route

  defp enqueue(state, step, entry) do
    cond do
      Workflow.batch?(step) -> add_to_batch(state, step, entry)
      full?(state, step) and step.on_full == :overflow -> overflow(state, step, entry)
      true -> update_in(state.queues[step.name], &:queue.in(entry, &1))
    end
  end

  defp full?(state, step) do
    step.max_queue != nil and not Workflow.batch?(step) and
      :queue.len(state.queues[step.name]) >= step.max_queue
  end

  # A step waits while any step after it is full and set to wait.
  defp held_back?(state, step) do
    Enum.any?(state.next[step.name], &(&1.on_full == :wait and full?(state, &1)))
  end

  # An item that didn't fit: recorded on the full step, then down its
  # `overflow` route.
  defp overflow(state, step, entry) do
    now = DateTime.utc_now()

    state
    |> add_row(%{
      step: step.name,
      item: nil,
      from_item: entry.from,
      status: "overflow",
      input: entry.value,
      started_at: now,
      finished_at: now
    })
    |> count(step.name, :overflow)
    |> produced(step, nil, entry.steps, [{entry.value, "overflow"}])
  end

  # -- starting executions --

  # Starts what can start, flushes batches nothing more can reach, and lets
  # held-back emits go. Repeats until nothing changes, since starting one
  # step can make room for the one before it.
  defp advance(state) do
    state = flush_idle_batches(state)
    {state, started?} = start_ready(state)
    state = release_held(state)
    if started?, do: advance(state), else: schedule_flush(state)
  end

  defp start_ready(%{ending: ending} = state) when ending != nil, do: {state, false}

  defp start_ready(state) do
    Enum.reduce(state.order, {state, false}, fn name, {state, started?} ->
      step = state.steps[name]

      if Workflow.batch?(step) do
        {state, started?}
      else
        {state, n} = start_step(state, step, 0)
        {state, started? or n > 0}
      end
    end)
  end

  defp start_step(state, step, n) do
    name = step.name

    cond do
      :queue.is_empty(state.queues[name]) -> {state, n}
      state.running[name] >= step.concurrency -> {state, n}
      held_back?(state, step) -> {state, n}
      (wait = delay_left(state, step)) > 0 -> {wait_for_delay(state, name, wait), n}
      true -> state |> launch(step) |> start_step(step, n + 1)
    end
  end

  defp delay_left(%{last_start: last_start}, %{delay: delay, name: name}) do
    case last_start do
      %{^name => at} when delay > 0 -> delay - (System.monotonic_time(:millisecond) - at)
      _ -> 0
    end
  end

  defp wait_for_delay(state, name, ms) do
    if name in state.delay_timers do
      state
    else
      Process.send_after(self(), {:delay_done, name}, ms)
      %{state | delay_timers: MapSet.put(state.delay_timers, name)}
    end
  end

  defp launch(state, step) do
    name = step.name
    {{:value, entry}, queue} = :queue.out(state.queues[name])
    task = StepTask.start(self(), %{step: step, input: entry.value, steps: entry.steps})

    if step.timeout > 0, do: Process.send_after(self(), {:timeout, task.ref}, step.timeout)

    exec = %{
      task: task,
      step: name,
      no: state.started[name],
      from: entry.from,
      lineage: entry.steps,
      input: entry.value,
      started_at: DateTime.utc_now(),
      emitted: []
    }

    %{
      state
      | queues: Map.put(state.queues, name, queue),
        execs: Map.put(state.execs, task.ref, exec),
        pids: Map.put(state.pids, task.pid, task.ref),
        running: Map.update!(state.running, name, &(&1 + 1)),
        started: Map.update!(state.started, name, &(&1 + 1)),
        last_start: Map.put(state.last_start, name, System.monotonic_time(:millisecond))
    }
  end

  defp release_held(state) do
    {go, stay} =
      Enum.split_with(state.held, fn {_from, name} ->
        state.ending != nil or not held_back?(state, state.steps[name])
      end)

    Enum.each(go, fn {from, _name} -> GenServer.reply(from, :ok) end)
    %{state | held: stay}
  end

  # -- finishing executions --

  defp execution_done(state, ref, %{status: :ok} = result) do
    {exec, state} = pop_exec(state, ref)
    step = state.steps[exec.step]
    emitted = Enum.reverse(exec.emitted)
    returned = split(result.output)
    items = emitted ++ returned
    output = if emitted == [], do: result.output, else: items

    state =
      state
      |> add_row(row(exec, "ok", result.input, output, result.route, nil))
      |> count(step.name, :ok)
      |> keep_result(step, exec.no, output, items)

    if state.ending,
      do: state,
      else: produced(state, step, exec.no, exec.lineage, Enum.map(returned, &{&1, result.route}))
  end

  defp execution_done(state, ref, %{status: :error, error: error, input: input}) do
    failed(state, ref, :error, error["message"], input)
  end

  # An execution that failed, timed out, crashed, or was killed.
  defp failed(state, ref, status, message, input \\ nil) do
    {exec, state} = pop_exec(state, ref)
    step = state.steps[exec.step]
    input = if input == nil, do: exec.input, else: input
    emitted = if exec.emitted == [], do: nil, else: Enum.reverse(exec.emitted)

    state =
      state
      |> add_row(row(exec, to_string(status), input, emitted, nil, %{"message" => message}))
      |> count(step.name, :failed)

    cond do
      state.ending ->
        state

      step.on_fail == :end_run ->
        error = %{"step" => step.name, "item" => exec.no, "message" => message}
        stop_everything(state, {"failed", error})

      true ->
        item = %{"error" => message, "input" => input}
        produced(state, step, exec.no, exec.lineage, [{item, "failed"}])
    end
  end

  defp pop_exec(state, ref) do
    {exec, execs} = Map.pop(state.execs, ref)

    {exec,
     %{
       state
       | execs: execs,
         pids: Map.delete(state.pids, exec.task.pid),
         running: Map.update!(state.running, exec.step, &(&1 - 1))
     }}
  end

  defp row(exec, status, input, output, route, error) do
    %{
      step: exec.step,
      item: exec.no,
      from_item: exec.from,
      status: status,
      route: route,
      input: input,
      output: output,
      error: error,
      started_at: exec.started_at,
      finished_at: DateTime.utc_now()
    }
  end

  defp count(state, name, key), do: update_in(state.counts[name][key], &(&1 + 1))

  defp keep_result(state, step, number, output, items) do
    if step.name in state.last,
      do:
        update_in(
          state.results,
          &Map.update(&1, step.name, [{number, output, items}], fn r ->
            [{number, output, items} | r]
          end)
        ),
      else: state
  end

  # -- batches --

  defp new_batch, do: %{items: [], token: nil}

  defp add_to_batch(state, step, entry) do
    batch = state.batches[step.name]
    wait = step.config["wait"]

    token =
      cond do
        batch.token -> batch.token
        wait -> start_batch_timer(step.name, wait)
        true -> nil
      end

    state = put_in(state.batches[step.name], %{items: [entry | batch.items], token: token})

    if length(state.batches[step.name].items) >= step.config["size"],
      do: flush_batch(state, step),
      else: state
  end

  defp start_batch_timer(name, wait) do
    token = make_ref()
    Process.send_after(self(), {:batch_wait, name, token}, wait)
    token
  end

  # Hands on everything in a batch as one item: {"items": [...]}.
  defp flush_batch(state, step) do
    case Enum.reverse(state.batches[step.name].items) do
      [] ->
        state

      entries ->
        state = put_in(state.batches[step.name], new_batch())
        values = Enum.map(entries, & &1.value)
        {:ok, output} = PurpleFlow.Nodes.Batch.execute(values, step.config)
        number = state.started[step.name]
        now = DateTime.utc_now()

        state
        |> Map.update!(:started, &Map.update!(&1, step.name, fn n -> n + 1 end))
        |> add_row(%{
          step: step.name,
          item: number,
          from_item: nil,
          status: "ok",
          input: values,
          output: output,
          started_at: now,
          finished_at: now
        })
        |> count(step.name, :ok)
        |> keep_result(step, number, output, [output])
        |> produced(step, number, shared_lineage(entries), [{output, nil}])
    end
  end

  # What every item in the batch agrees on: the earlier outputs they share.
  defp shared_lineage([first | rest]) do
    Map.filter(first.steps, fn {name, output} ->
      Enum.all?(rest, &(Map.get(&1.steps, name) == output))
    end)
  end

  # A batch goes once nothing more can reach it.
  defp flush_idle_batches(%{ending: ending} = state) when ending != nil, do: state

  defp flush_idle_batches(state) do
    Enum.reduce(state.batches, state, fn {name, batch}, state ->
      step = state.steps[name]

      if batch.items != [] and Enum.all?(step.ancestors, &idle?(state, &1)),
        do: flush_batch(state, step),
        else: state
    end)
  end

  defp idle?(state, name) do
    :queue.is_empty(state.queues[name]) and state.running[name] == 0 and
      match?(%{items: []}, Map.get(state.batches, name, %{items: []}))
  end

  # -- ending the run --

  # Nothing new starts; queues and batches are dropped.
  defp stop_everything(state, ending) do
    %{
      state
      | ending: ending,
        queues: Map.new(state.queues, fn {name, _} -> {name, :queue.new()} end),
        batches: Map.new(state.batches, fn {name, _} -> {name, new_batch()} end)
    }
  end

  defp continue(state) do
    state = advance(state)

    if done?(state), do: finish(state), else: {:noreply, state}
  end

  defp done?(%{execs: execs} = state) when execs == %{} do
    state.ending != nil or
      (Enum.all?(state.queues, fn {_, q} -> :queue.is_empty(q) end) and
         Enum.all?(state.batches, fn {_, b} -> b.items == [] end))
  end

  defp done?(_state), do: false

  defp finish(state) do
    state = save_rows(state)

    status =
      case state.ending do
        nil ->
          Runs.finish_run(state.id, "complete", output: run_output(state))
          "complete"

        {status, error} ->
          Runs.finish_run(state.id, status, error: error)
          status
      end

    announce_finished(state, status)
    {:stop, :normal, %{state | finished: true}}
  end

  defp announce_finished(state, status) do
    if state.stream_to, do: send(state.stream_to, {:run_finished, state.id, status})
    PurpleFlow.broadcast(state.id, {:run_finished, state.id, status}, runs: true)
  end

  # The output of the last steps (the ones nothing comes after) that ran.
  defp run_output(state) do
    outputs =
      for name <- state.order, results = state.results[name], results != nil do
        {name, step_output(results)}
      end

    case outputs do
      [] -> nil
      [{_name, output}] -> output
      many -> Map.new(many)
    end
  end

  # Ran once: that execution's output. More: all their items, in start order.
  defp step_output([{_number, output, _items}]), do: output

  defp step_output(results) do
    results |> Enum.sort_by(&elem(&1, 0)) |> Enum.flat_map(&elem(&1, 2))
  end

  # -- saving --

  defp add_row(state, fields),
    do: %{state | rows: [Map.put(fields, :run_id, state.id) | state.rows]}

  defp schedule_flush(%{flush_timer: nil} = state) do
    %{state | flush_timer: Process.send_after(self(), :flush, @flush_ms)}
  end

  defp schedule_flush(state), do: state

  # Saves the rows held so far in one insert, then says how things stand.
  defp save_rows(state) do
    if state.rows != [] do
      try do
        Runs.save_steps(Enum.reverse(state.rows))
      rescue
        error ->
          Logger.error("couldn't save steps of run #{state.id}: #{Exception.message(error)}")
      end
    end

    PurpleFlow.broadcast(state.id, {:run_progress, state.id, progress(state)})
    %{state | rows: []}
  end

  defp progress(state) do
    Map.new(state.order, fn name ->
      queued =
        case state.batches do
          %{^name => batch} -> length(batch.items)
          _ -> :queue.len(state.queues[name])
        end

      {name,
       Map.merge(state.counts[name], %{
         queued: queued,
         running: state.running[name],
         concurrency: state.steps[name].concurrency
       })}
    end)
  end

  defp format_seconds(seconds) when seconds == trunc(seconds), do: trunc(seconds)
  defp format_seconds(seconds), do: seconds
end
