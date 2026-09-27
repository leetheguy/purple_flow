defmodule PurpleFlow.Runner.Reaper do
  @moduledoc """
  Kills what finished Code scripts left running. See
  `PurpleFlow.Runner.Server`.

  Each script runs under its own group leader, which every process it
  spawns inherits. When a script is done, the server hands its leader here.
  Finding the processes means looking at every process in the runner, so
  finished leaders are gathered and swept together: one pass over the
  process list for however many scripts finished since the last one, and at
  most one pass every 100 ms. With thousands of scripts finishing at
  once, one pass each would cost thousands of passes over thousands of
  processes.
  """

  use GenServer

  @min_interval_ms 100

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Kills, soon, every process whose group leader is `leader`."
  def reap(leader), do: GenServer.cast(__MODULE__, {:reap, leader})

  @impl true
  def init(nil), do: {:ok, %{leaders: MapSet.new(), swept_at: now() - @min_interval_ms}}

  @impl true
  def handle_cast({:reap, leader}, state) do
    state = %{state | leaders: MapSet.put(state.leaders, leader)}
    {:noreply, state, wait(state)}
  end

  # A timeout only fires once the mailbox is empty, so every leader waiting
  # in it is in this sweep.
  @impl true
  def handle_info(:timeout, %{leaders: leaders} = state) do
    for pid <- Process.list(),
        {:group_leader, leader} <- [Process.info(pid, :group_leader)],
        MapSet.member?(leaders, leader),
        do: Process.exit(pid, :kill)

    {:noreply, %{state | leaders: MapSet.new(), swept_at: now()}}
  end

  defp wait(state), do: max(0, state.swept_at + @min_interval_ms - now())

  defp now, do: System.monotonic_time(:millisecond)
end
