defmodule PurpleFlow.Nodes.Postgres.Pool do
  @moduledoc """
  Looks after one `database_url`'s Postgrex pool for the Postgres node.

  The pool opens on the first query and closes, connections and all, once
  no query has used it for `idle_ms` (default one minute). The next query
  opens it again. So a burst of items shares one pool, and a database
  nothing is querying holds no connections.

  It counts queries in flight by monitoring each caller, so a step that
  crashes mid-query doesn't keep the pool open forever.
  """

  use GenServer, restart: :temporary

  @idle_ms 60_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: opts[:name])

  @doc "Runs `fun` with a connection to pass to `Postgrex.query/3`."
  def run(pool, fun) do
    case GenServer.call(pool, :checkout, :infinity) do
      {:ok, conn, ref} ->
        try do
          fun.(conn)
        after
          GenServer.cast(pool, {:checkin, ref})
        end

      {:error, reason} ->
        {:error, "couldn't connect: #{inspect(reason)}"}
    end
  end

  @impl true
  def init(opts) do
    # Closing the pool must not take this process down with it.
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       postgrex: Keyword.fetch!(opts, :postgrex),
       idle_ms: Keyword.get(opts, :idle_ms, @idle_ms),
       conn: nil,
       users: MapSet.new(),
       idle: nil
     }}
  end

  @impl true
  def handle_call(:checkout, {caller, _}, state) do
    case open(state) do
      {:ok, state} ->
        ref = Process.monitor(caller)
        state = %{cancel_idle(state) | users: MapSet.put(state.users, ref)}
        {:reply, {:ok, state.conn, ref}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_cast({:checkin, ref}, state) do
    Process.demonitor(ref, [:flush])
    {:noreply, done(state, ref)}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state), do: {:noreply, done(state, ref)}

  def handle_info({:idle, token}, %{idle: {_timer, token}} = state) do
    GenServer.stop(state.conn)
    {:noreply, %{state | conn: nil, idle: nil}}
  end

  # The pool went down on its own; the next query opens a new one.
  def handle_info({:EXIT, conn, _reason}, %{conn: conn} = state),
    do: {:noreply, %{cancel_idle(state) | conn: nil}}

  # A stale idle timer, or the exit of a pool we closed.
  def handle_info(_message, state), do: {:noreply, state}

  defp open(%{conn: nil} = state) do
    with {:ok, conn} <- Postgrex.start_link(state.postgrex), do: {:ok, %{state | conn: conn}}
  end

  defp open(state), do: {:ok, state}

  defp done(state, ref) do
    state = %{state | users: MapSet.delete(state.users, ref)}

    if MapSet.size(state.users) == 0 and state.conn != nil and state.idle == nil do
      token = make_ref()
      %{state | idle: {Process.send_after(self(), {:idle, token}, state.idle_ms), token}}
    else
      state
    end
  end

  defp cancel_idle(%{idle: nil} = state), do: state

  defp cancel_idle(%{idle: {timer, _token}} = state) do
    Process.cancel_timer(timer)
    %{state | idle: nil}
  end
end
