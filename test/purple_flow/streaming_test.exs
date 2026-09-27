defmodule PurpleFlow.StreamingTest do
  # Nodes handing on items while they run: specs/150_streaming.md.
  use PurpleFlow.DataCase, async: false

  import PurpleFlow.WorkflowHelpers

  test "emitted items move on before the node returns" do
    workflow =
      steps!(
        "emits",
        """
        [[steps]]
        name = "talk"
        node = "talk.toml"
        [[steps]]
        name = "hear"
        node = "n.toml"
        after = ["talk"]
        """,
        %{
          "talk.toml" => fake_node(%{"emit" => [1, [2, 3]], "after_emit" => 200}),
          "n.toml" => fake_node()
        }
      )

    result = run!(workflow, nil)
    [talk] = rows(result, "talk")

    # An emitted list splits like a returned one; the record keeps every item.
    assert talk.output == [1, 2, 3]
    assert result |> rows("hear") |> Enum.map(& &1.input) |> Enum.sort() == [1, 2, 3]

    for hear <- rows(result, "hear"),
        do: assert(DateTime.compare(hear.started_at, talk.finished_at) == :lt)
  end

  test "emit waits while the step after is full" do
    workflow =
      steps!(
        "emit_waits",
        """
        [[steps]]
        name = "talk"
        node = "talk.toml"
        [[steps]]
        name = "slow"
        node = "slow.toml"
        after = ["talk"]
        concurrency = 1
        max_queue = 1
        """,
        %{
          "talk.toml" => fake_node(%{"emit" => [1, 2, 3, 4, 5]}),
          "slow.toml" => fake_node(%{"sleep" => 50})
        }
      )

    result = run!(workflow, nil)
    [talk] = rows(result, "talk")
    slow = rows(result, "slow")
    assert length(slow) == 5

    # Without waiting, talk would be done in a millisecond. It can only hand
    # over item 5 once slow has started item 3.
    assert DateTime.compare(talk.finished_at, Enum.at(slow, 2).started_at) != :lt
  end

  test "an emitted item that isn't JSON fails the execution" do
    defmodule BadEmit do
      @behaviour PurpleFlow.Node
      def execute(_input, _config) do
        PurpleFlow.Node.emit({:not, :json})
        {:ok, []}
      end
    end

    workflow =
      steps!(
        "bad_emit",
        """
        [[steps]]
        name = "a"
        node = "a.toml"
        """,
        %{"a.toml" => ~s(module = "PurpleFlow.StreamingTest.BadEmit")}
      )

    assert [%{status: "error", error: %{"message" => "emitted isn't JSON" <> _}}] =
             rows(run!(workflow, nil), "a")
  end

  test "an SSH step's lines move on to the next step" do
    server =
      PurpleFlow.Test.SshServer.start!(fn "shout", stdin ->
        [{:out, String.upcase(stdin) <> "\n"}, {:out, "done\n"}]
      end)

    ssh =
      TomlElixir.encode!(%{
        "module" => "PurpleFlow.Nodes.Ssh",
        "config" => %{
          "host" => "127.0.0.1",
          "port" => server.port,
          "user" => "deploy",
          "password" => "hunter2",
          "host_key" => server.host_key_fingerprint,
          "command" => "shout",
          "stdin" => "{{ input.name }}",
          "stream" => "lines"
        }
      })

    workflow =
      steps!(
        "ssh_stream",
        """
        [[steps]]
        name = "remote"
        node = "remote.toml"
        [[steps]]
        name = "hear"
        node = "n.toml"
        after = ["remote"]
        """,
        %{"remote.toml" => ssh, "n.toml" => fake_node()}
      )

    result = run!(workflow, %{"name" => "ada"}, 10_000)
    assert [%{status: "ok", output: ["ADA", "done"]}] = rows(result, "remote")
    assert result |> rows("hear") |> Enum.map(& &1.input) |> Enum.sort() == ["ADA", "done"]
  end
end
