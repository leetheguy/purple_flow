defmodule PurpleFlow.WatchdogTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias PurpleFlow.Watchdog

  doctest Watchdog

  # Each check is driven by hand (send :check) with an interval far longer
  # than any test, so nothing depends on timing.
  @hour 3_600_000

  defp start(stub, opts \\ []) do
    name = :"watchdog_#{System.unique_integer([:positive])}"
    test = self()
    Req.Test.stub(name, stub)

    opts =
      Keyword.merge(
        [
          interval: @hour,
          timeout: 1_000,
          failures: 3,
          url: "http://watchdog.test/health",
          req_options: [plug: {Req.Test, name}],
          halt: fn status -> send(test, {:halted, status}) end
        ],
        opts
      )

    pid = start_supervised!({Watchdog, opts})
    Req.Test.allow(name, test, pid)
    pid
  end

  defp check(pid) do
    send(pid, :check)
    # Waits until the check above has been handled.
    _ = :sys.get_state(pid)
  end

  defp ok(conn), do: Plug.Conn.send_resp(conn, 200, "ok")
  defp down(conn), do: Plug.Conn.send_resp(conn, 503, "down")

  test "halts with status 1 after `failures` failed checks in a row, and logs why" do
    pid = start(&down/1)

    log =
      capture_log(fn ->
        check(pid)
        check(pid)
        refute_received {:halted, _}
        check(pid)
      end)

    assert_received {:halted, 1}
    assert log =~ "not answering"
    assert log =~ "503"
  end

  test "a passing check resets the count" do
    {:ok, answers} = Agent.start_link(fn -> [:down, :ok, :down, :down] end)

    stub = fn conn ->
      case Agent.get_and_update(answers, fn [a | rest] -> {a, rest} end) do
        :ok -> ok(conn)
        :down -> down(conn)
      end
    end

    pid = start(stub)
    capture_log(fn -> for _ <- 1..4, do: check(pid) end)
    refute_received {:halted, _}
  end

  test "a request error counts as a failure" do
    pid = start(&Req.Test.transport_error(&1, :econnrefused), failures: 1)
    log = capture_log(fn -> check(pid) end)
    assert_received {:halted, 1}
    assert log =~ "connection refused"
  end

  test "a timeout counts as a failure" do
    pid = start(&Req.Test.transport_error(&1, :timeout), failures: 1)
    log = capture_log(fn -> check(pid) end)
    assert_received {:halted, 1}
    assert log =~ "timeout"
  end

  test "any answer but 200 counts as a failure" do
    pid = start(&Plug.Conn.send_resp(&1, 204, ""), failures: 1)
    capture_log(fn -> check(pid) end)
    assert_received {:halted, 1}
  end

  test "a failed check is tried once, not retried" do
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    pid =
      start(
        fn conn ->
          Agent.update(calls, &(&1 + 1))
          Req.Test.transport_error(conn, :econnrefused)
        end,
        failures: 5
      )

    capture_log(fn -> check(pid) end)
    assert Agent.get(calls, & &1) == 1
  end

  test "says when it starts what it checks, how often, and when it halts" do
    # Tests log warnings and up only; this line is info.
    Logger.put_module_level(Watchdog, :info)
    on_exit(fn -> Logger.delete_module_level(Watchdog) end)

    log = capture_log(fn -> start(&ok/1, interval: 120_000, failures: 4) end)
    assert log =~ "checking http://watchdog.test/health every 120 s, halting after 4 failures"
  end

  test "a healthy app is never halted" do
    pid = start(&ok/1, failures: 1)
    for _ <- 1..5, do: check(pid)
    refute_received {:halted, _}
  end

  test "nothing is checked before the first interval" do
    test = self()
    pid = start(fn conn -> send(test, :checked) && ok(conn) end)
    _ = :sys.get_state(pid)
    refute_received :checked
  end

  test "the first check comes after one interval, and the next after another" do
    test = self()
    start(fn conn -> send(test, :checked) && ok(conn) end, interval: 10)
    assert_receive :checked
    assert_receive :checked
  end

  describe "settings/1" do
    test "defaults: every 30 s, 10 s timeout, halt after 3 failures" do
      assert Watchdog.settings(%{}) == [interval: 30_000, timeout: 10_000, failures: 3]
    end

    test "reads the environment variables, in seconds" do
      env = %{
        "PURPLEFLOW_WATCHDOG_INTERVAL" => "5",
        "PURPLEFLOW_WATCHDOG_TIMEOUT" => "2",
        "PURPLEFLOW_WATCHDOG_FAILURES" => "7"
      }

      assert Watchdog.settings(env) == [interval: 5_000, timeout: 2_000, failures: 7]
    end

    test "1 is the smallest timeout and number of failures" do
      env = %{"PURPLEFLOW_WATCHDOG_TIMEOUT" => "1", "PURPLEFLOW_WATCHDOG_FAILURES" => "1"}
      assert Watchdog.settings(env) == [interval: 30_000, timeout: 1_000, failures: 1]
    end

    test "an interval of 0 means off" do
      assert Watchdog.settings(%{"PURPLEFLOW_WATCHDOG_INTERVAL" => "0"}) == :off
    end

    test "a value that isn't a whole number of at least 1 is refused" do
      for {name, value} <- [
            {"PURPLEFLOW_WATCHDOG_INTERVAL", "-1"},
            {"PURPLEFLOW_WATCHDOG_TIMEOUT", "0"},
            {"PURPLEFLOW_WATCHDOG_FAILURES", "three"}
          ] do
        assert_raise ArgumentError, ~r/#{name}/, fn -> Watchdog.settings(%{name => value}) end
      end
    end
  end

  describe "child_spec in the app" do
    test "is nil when the watchdog isn't configured, as in dev and test" do
      assert Watchdog.app_child(%{}, false) == nil
    end

    test "is nil when the interval is 0" do
      assert Watchdog.app_child(%{"PURPLEFLOW_WATCHDOG_INTERVAL" => "0"}, true) == nil
    end

    test "checks the app's own /health over loopback, on the endpoint's port" do
      {Watchdog, opts} = Watchdog.app_child(%{}, true)
      port = PurpleFlowWeb.Endpoint.config(:http)[:port]
      assert opts[:url] == "http://127.0.0.1:#{port}/health"
      assert opts[:interval] == 30_000
    end

    # The app builds its child list before the endpoint starts, so the port
    # must come from the config, not the running endpoint. (A release once
    # failed to boot over this.) Here the config says 4321 while the running
    # endpoint is elsewhere.
    test "reads the port from the config, which exists before the endpoint starts" do
      endpoint = Application.get_env(:purple_flow, PurpleFlowWeb.Endpoint)

      Application.put_env(
        :purple_flow,
        PurpleFlowWeb.Endpoint,
        Keyword.put(endpoint, :http, port: 4321)
      )

      on_exit(fn -> Application.put_env(:purple_flow, PurpleFlowWeb.Endpoint, endpoint) end)

      assert {Watchdog, opts} = Watchdog.app_child(%{}, true)
      assert opts[:url] == "http://127.0.0.1:4321/health"
    end
  end
end
