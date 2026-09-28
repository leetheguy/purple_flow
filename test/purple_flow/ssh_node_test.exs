defmodule PurpleFlow.SshNodeTest do
  # The SSH node against a real SSH server on localhost: specs/170_ssh.md.
  use ExUnit.Case, async: true

  alias PurpleFlow.Nodes.Ssh
  alias PurpleFlow.Test.SshServer

  defp config(server, extra) do
    Map.merge(
      %{
        "host" => "127.0.0.1",
        "port" => server.port,
        "user" => "deploy",
        "password" => "hunter2"
      },
      extra
    )
  end

  test "runs the command and returns its output" do
    server =
      SshServer.start!(fn "greet", stdin -> [{:out, "hi #{stdin}\n"}, {:err, "note\n"}] end)

    assert {:ok, %{"stdout" => "hi Ada\n", "stderr" => "note\n", "exit_status" => 0}} =
             Ssh.execute(nil, config(server, %{"command" => "greet", "stdin" => "Ada"}))
  end

  test "output bigger than SSH's flow control window arrives whole" do
    chunk = String.duplicate("x", 32_000) <> "\n"
    server = SshServer.start!(fn "big", _ -> List.duplicate({:out, chunk}, 200) end)

    assert {:ok, %{"stdout" => stdout}} = Ssh.execute(nil, config(server, %{"command" => "big"}))
    assert byte_size(stdout) == 200 * byte_size(chunk)
  end

  test "stdin_file sends a run file's bytes, bigger than the flow control window" do
    run_id = PurpleFlow.Id.generate()
    on_exit(fn -> PurpleFlow.RunFiles.delete_run(run_id) end)
    bytes = :crypto.strong_rand_bytes(3_000_000)
    source = Path.join(System.tmp_dir!(), "pf_ssh_#{run_id}")
    File.write!(source, bytes)
    ref = PurpleFlow.RunFiles.save(run_id, source, "blob.bin", nil)

    server = SshServer.start!(fn "cat", stdin -> [{:out, stdin}] end)

    assert {:ok, %{"stdout" => ^bytes}} =
             Ssh.execute(nil, config(server, %{"command" => "cat", "stdin_file" => ref}))
  end

  test "stdin_file that isn't a file, or is gone, fails before connecting" do
    config = config(%{port: 1}, %{"command" => "cat"})

    assert {:error, "not a file" <> _} = Ssh.execute(nil, Map.put(config, "stdin_file", "x"))

    gone = %{"file" => PurpleFlow.Id.generate() <> "/" <> PurpleFlow.Id.generate()}
    assert {:error, "file " <> _} = Ssh.execute(nil, Map.put(config, "stdin_file", gone))
  end

  test "stdin and stdin_file together fail to load" do
    config = config(%{port: 22}, %{"command" => "cat", "stdin" => "a", "stdin_file" => "b"})
    assert {:error, "takes stdin or stdin_file, not both"} = Ssh.prepare(config, ".", ".")
  end

  test "stdin that isn't text is sent as JSON" do
    server = SshServer.start!(fn "cat", stdin -> [{:out, stdin}] end)

    assert {:ok, %{"stdout" => ~s({"a":1})}} =
             Ssh.execute(nil, config(server, %{"command" => "cat", "stdin" => %{"a" => 1}}))
  end

  test "logs in with a private key, even one whose line breaks were lost" do
    server = SshServer.start!(fn "whoami", _ -> [{:out, "deploy"}] end)
    pasted = String.replace(server.user_key, "\n", " ")

    config =
      server
      |> config(%{"command" => "whoami", "private_key" => pasted, "port" => "#{server.port}"})
      |> Map.delete("password")

    assert {:ok, %{"stdout" => "deploy"}} = Ssh.execute(nil, config)
    config = Map.put(config, "private_key", server.rsa_user_key)
    assert {:ok, %{"stdout" => "deploy"}} = Ssh.execute(nil, config)
  end

  test "a wrong password is an error" do
    server = SshServer.start!(fn _, _ -> [] end)

    assert {:error, "SSH connection to 127.0.0.1 failed: " <> _} =
             Ssh.execute(nil, config(server, %{"command" => "x", "password" => "nope"}))
  end

  test "connect_timeout gives up on a server that never answers" do
    # Takes the connection but never speaks SSH.
    {:ok, silent} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(silent)
    config = %{"host" => "127.0.0.1", "port" => port, "user" => "u", "password" => "p"}

    assert {:error, "SSH connection to 127.0.0.1 failed: " <> _} =
             Ssh.execute(nil, Map.merge(config, %{"command" => "x", "connect_timeout" => 0.2}))
  end

  test "a non-zero exit status is an error, with stderr" do
    server =
      SshServer.start!(fn "false", _ ->
        [{:out, "partial"}, {:err, "no such file\n"}, {:exit, 2}]
      end)

    assert {:error, "exit status 2: no such file"} =
             Ssh.execute(nil, config(server, %{"command" => "false"}))
  end

  test "a command killed by a signal is an error" do
    server = SshServer.start!(fn "sleep", _ -> [{:signal, "KILL"}] end)

    assert {:error, "killed by signal KILL" <> _} =
             Ssh.execute(nil, config(server, %{"command" => "sleep"}))
  end

  describe "host_key" do
    test "a matching fingerprint connects" do
      server = SshServer.start!(fn _, _ -> [{:out, "ok"}] end)
      config = config(server, %{"command" => "x", "host_key" => server.host_key_fingerprint})
      assert {:ok, %{"stdout" => "ok"}} = Ssh.execute(nil, config)
    end

    test "any other key is refused" do
      server = SshServer.start!(fn _, _ -> [{:out, "ok"}] end)
      config = config(server, %{"command" => "x", "host_key" => "SHA256:not-this-one"})
      assert {:error, "SSH connection to 127.0.0.1 failed: " <> _} = Ssh.execute(nil, config)
      refute_received {:ssh_channel_closed, _}
    end
  end

  describe "stream" do
    test "\"lines\" emits each line of stdout as it arrives" do
      test = self()

      server =
        SshServer.start!(fn "tail", _ ->
          [{:out, "one\ntw"}, {:wait}, {:out, "o\n\nthree\r\nfo"}, {:out, "ur"}]
        end)

      task =
        Task.async(fn ->
          Process.put(:purple_flow_emit, fn value, _route -> send(test, {:emitted, value}) end)
          Ssh.execute(nil, config(server, %{"command" => "tail", "stream" => "lines"}))
        end)

      # The first line comes out while the command is still running.
      assert_receive {:waiting, channel}, 5000
      assert_receive {:emitted, "one"}
      refute_received {:emitted, _}
      send(channel, :go)

      assert Task.await(task) == {:ok, []}
      assert_received {:emitted, "two"}
      assert_received {:emitted, "three"}
      assert_received {:emitted, "four"}
    end

    test "\"ndjson\" emits each line decoded" do
      server =
        SshServer.start!(fn "logs", _ -> [{:out, ~s({"a":1}\n{"b")}, {:out, ~s(:2}\n)}] end)

      assert {:ok, []} =
               Ssh.execute(nil, config(server, %{"command" => "logs", "stream" => "ndjson"}))

      assert_received {:emit, %{"a" => 1}, nil}
      assert_received {:emit, %{"b" => 2}, nil}
    end

    test "a non-zero exit is still an error, after what was already emitted" do
      server =
        SshServer.start!(fn "logs", _ -> [{:out, "one\n"}, {:err, "disk full"}, {:exit, 1}] end)

      assert {:error, "exit status 1: disk full"} =
               Ssh.execute(nil, config(server, %{"command" => "logs", "stream" => "lines"}))

      assert_received {:emit, "one", nil}
    end
  end

  test "a killed execution closes the channel" do
    test = self()

    server =
      SshServer.start!(fn "hang", _ ->
        send(test, :running)
        [{:hang}]
      end)

    {pid, ref} = spawn_monitor(fn -> Ssh.execute(nil, config(server, %{"command" => "hang"})) end)
    assert_receive :running, 5000
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    assert_receive {:ssh_channel_closed, "hang"}, 2000
  end

  test "config mistakes fail at load time" do
    base = %{"host" => "h", "user" => "u", "command" => "c", "password" => "p"}
    assert {:ok, _} = Ssh.prepare(base, ".", ".")

    assert {:error, "missing host, command"} =
             Ssh.prepare(Map.drop(base, ~w(host command)), ".", ".")

    assert {:error, "needs a password or a private_key"} =
             Ssh.prepare(Map.delete(base, "password"), ".", ".")

    assert {:error, "stream must be" <> _} = Ssh.prepare(Map.put(base, "stream", "sse"), ".", ".")
  end
end
