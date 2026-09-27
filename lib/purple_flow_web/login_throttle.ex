defmodule PurpleFlowWeb.LoginThrottle do
  @moduledoc """
  Locks out an IP address after too many failed sign-ins: 3 failures, each
  within 4 hours of the last, lock that address out for 4 hours from the
  last one. While locked out, its sign-ins are refused without checking the
  password, even a right one. A successful sign-in clears its count.

  Counts both the `/login` form and the admin login sent as Basic auth to
  `/fs/` (`PurpleFlowWeb.Auth`), since they're the same password.

  Kept in memory: restarting the app clears every lockout, which is also
  how to let yourself back in early.
  """

  use GenServer

  @table __MODULE__
  @max_failures 3
  @lockout_ms 4 * 60 * 60 * 1000
  @sweep_ms 10 * 60 * 1000

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Whether `ip` is locked out."
  def locked?(ip, now \\ now()) do
    case :ets.lookup(@table, ip) do
      [{^ip, count, expires_at}] -> count >= @max_failures and expires_at > now
      [] -> false
    end
  end

  @doc "Records a failed sign-in from `ip`."
  def fail(ip), do: GenServer.call(__MODULE__, {:fail, ip})

  @doc "Clears `ip`'s failures, after a successful sign-in."
  def clear(ip), do: :ets.delete(@table, ip)

  @doc "Clears everything. For tests."
  def reset, do: :ets.delete_all_objects(@table)

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    Process.send_after(self(), :sweep, @sweep_ms)
    {:ok, nil}
  end

  @impl true
  def handle_call({:fail, ip}, _from, state) do
    now = now()

    count =
      case :ets.lookup(@table, ip) do
        [{^ip, count, expires_at}] when expires_at > now -> count + 1
        _ -> 1
      end

    :ets.insert(@table, {ip, count, now + @lockout_ms})
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:"=<", :"$1", now()}], [true]}])
    Process.send_after(self(), :sweep, @sweep_ms)
    {:noreply, state}
  end

  defp now, do: System.monotonic_time(:millisecond)
end
