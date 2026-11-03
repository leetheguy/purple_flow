defmodule PurpleFlow.Watchdog do
  @moduledoc """
  Halts the app when it stops answering web requests, so Docker restarts it.
  See [specs/250](specs/250_watchdog.md).

  Docker restarts a container whose process exits, but not one that's still
  running and just hung. Every `interval`, this process asks the app's own
  `GET /health` over loopback. After `failures` failed checks in a row, it
  logs why and halts the VM with exit status 1 (`System.halt/1`). It halts
  outright on purpose: a graceful stop could hang on whatever broke the app.

  A check fails when the request errors, takes longer than `timeout`, or
  answers anything but `200`. One passing check resets the count.

  It runs in prod only, where `config :purple_flow, :watchdog, true` is set
  (`config/runtime.exs`); `PURPLEFLOW_WATCHDOG_*` environment variables tune
  it (see `settings/1`). A frozen VM can't run this at all; Erlang's `heart`
  covers that case (see the spec).

  ## Options

    * `:interval` — milliseconds between checks. The first check comes one
      interval after start, so a slow boot isn't a failure.
    * `:timeout` — milliseconds one check may take.
    * `:failures` — failed checks in a row before halting.
    * `:url` — the health URL to ask.
    * `:req_options` — extra options for `Req`, such as a test stub.
    * `:halt` — the function that halts, given the exit status. Defaults to
      `System.halt/1`; tests pass their own.
  """

  use GenServer
  require Logger

  @defaults %{
    "PURPLEFLOW_WATCHDOG_INTERVAL" => 30,
    "PURPLEFLOW_WATCHDOG_TIMEOUT" => 10,
    "PURPLEFLOW_WATCHDOG_FAILURES" => 3
  }

  @doc """
  Reads the watchdog's settings from environment variables (a map like
  `System.get_env/0` returns), filling in the defaults.

  Returns `[interval: ms, timeout: ms, failures: n]`, or `:off` when
  `PURPLEFLOW_WATCHDOG_INTERVAL` is `0`. Raises `ArgumentError` naming the
  variable when a value isn't a whole number in range.

      iex> PurpleFlow.Watchdog.settings(%{"PURPLEFLOW_WATCHDOG_FAILURES" => "5"})
      [interval: 30_000, timeout: 10_000, failures: 5]

      iex> PurpleFlow.Watchdog.settings(%{"PURPLEFLOW_WATCHDOG_INTERVAL" => "0"})
      :off
  """
  @spec settings(%{optional(String.t()) => String.t()}) :: keyword() | :off
  def settings(env) do
    case number(env, "PURPLEFLOW_WATCHDOG_INTERVAL", 0) do
      0 ->
        :off

      interval ->
        [
          interval: interval * 1000,
          timeout: number(env, "PURPLEFLOW_WATCHDOG_TIMEOUT", 1) * 1000,
          failures: number(env, "PURPLEFLOW_WATCHDOG_FAILURES", 1)
        ]
    end
  end

  # The variable's value as a whole number of at least `min`, or its default.
  defp number(env, name, min) do
    case Map.fetch(env, name) do
      :error ->
        Map.fetch!(@defaults, name)

      {:ok, value} ->
        case Integer.parse(value) do
          {n, ""} when n >= min ->
            n

          _ ->
            raise ArgumentError,
                  "#{name} must be a whole number of at least #{min}, got: #{inspect(value)}"
        end
    end
  end

  @doc """
  The child spec `PurpleFlow.Application` starts, or `nil` for none.

  `nil` unless `enabled?` (prod sets `config :purple_flow, :watchdog,
  true`), or when the interval is `0`. Otherwise the watchdog checks
  `http://127.0.0.1:<port>/health`, where `<port>` is the endpoint's own, read from its config.
  """
  @spec app_child(map(), boolean()) :: {module(), keyword()} | nil
  def app_child(env, enabled?) do
    with true <- enabled?, settings when is_list(settings) <- settings(env) do
      # From the config, not the running endpoint: this runs while the app
      # builds its child list, before the endpoint has started.
      port = Application.fetch_env!(:purple_flow, PurpleFlowWeb.Endpoint)[:http][:port]
      {__MODULE__, [url: "http://127.0.0.1:#{port}/health"] ++ settings}
    else
      _ -> nil
    end
  end

  @doc "Starts the watchdog. See the module doc for `opts`."
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    state = %{
      interval: Keyword.fetch!(opts, :interval),
      timeout: Keyword.fetch!(opts, :timeout),
      failures: Keyword.fetch!(opts, :failures),
      url: Keyword.fetch!(opts, :url),
      req_options: Keyword.get(opts, :req_options, []),
      halt: Keyword.get(opts, :halt, &System.halt/1),
      failed: 0
    }

    Logger.info(
      "watchdog: checking #{state.url} every #{div(state.interval, 1000)} s, " <>
        "halting after #{state.failures} failures in a row"
    )

    schedule(state)
    {:ok, state}
  end

  @impl true
  def handle_info(:check, state) do
    state =
      case check(state) do
        :ok ->
          %{state | failed: 0}

        {:error, reason} ->
          failed = state.failed + 1

          if failed >= state.failures do
            Logger.error(
              "the app is not answering #{state.url} (failed #{failed} in a row, " <>
                "last: #{reason}); halting so Docker restarts it"
            )

            # Gives the log line a chance to be written before the VM stops.
            Logger.flush()
            state.halt.(1)
          else
            Logger.warning("health check failed (#{failed} of #{state.failures}): #{reason}")
          end

          %{state | failed: failed}
      end

    schedule(state)
    {:noreply, state}
  end

  defp schedule(state), do: Process.send_after(self(), :check, state.interval)

  defp check(state) do
    options =
      [
        url: state.url,
        receive_timeout: state.timeout,
        connect_options: [timeout: state.timeout],
        retry: false
      ]
      |> Keyword.merge(state.req_options)

    case Req.get(options) do
      {:ok, %Req.Response{status: 200}} -> :ok
      {:ok, %Req.Response{status: status}} -> {:error, "answered #{status}"}
      {:error, exception} -> {:error, Exception.message(exception)}
    end
  end
end
