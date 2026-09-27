defmodule PurpleFlow.BatchTest do
  # The Batch node: specs/140_batch.md.
  use PurpleFlow.DataCase, async: false

  import PurpleFlow.WorkflowHelpers

  defp batch_node(config),
    do: TomlElixir.encode!(%{"module" => "PurpleFlow.Nodes.Batch", "config" => config})

  defp flow(name, src, batch, after_batch \\ fake_node()) do
    steps!(
      name,
      """
      [[steps]]
      name = "src"
      node = "src.toml"
      concurrency = 1
      [[steps]]
      name = "chunk"
      node = "chunk.toml"
      after = ["src"]
      [[steps]]
      name = "use"
      node = "use.toml"
      after = ["chunk"]
      """,
      %{"src.toml" => src, "chunk.toml" => batch, "use.toml" => after_batch}
    )
  end

  test "items go on in batches of size, and the last partial batch goes too" do
    result = run!(flow("sizes", fake_node(), batch_node(%{"size" => 2})), [1, 2, 3, 4, 5])

    assert result |> rows("use") |> Enum.map(& &1.input) ==
             [%{"items" => [1, 2]}, %{"items" => [3, 4]}, %{"items" => [5]}]

    assert [%{input: [1, 2], output: %{"items" => [1, 2]}} | _] = rows(result, "chunk")
    assert result.run.output == [%{"items" => [1, 2]}, %{"items" => [3, 4]}, %{"items" => [5]}]
  end

  test "a full batch goes before the steps before it are done" do
    result =
      run!(flow("early", fake_node(%{"sleep" => 40}), batch_node(%{"size" => 2})), [1, 2, 3, 4])

    [first_use | _] = rows(result, "use")
    last_src = List.last(rows(result, "src"))
    assert DateTime.compare(first_use.started_at, last_src.finished_at) == :lt
  end

  test "wait sends a partial batch while more is still coming" do
    result =
      run!(
        flow("waits", fake_node(%{"sleep" => 60}), batch_node(%{"size" => 100, "wait" => 20})),
        [1, 2, 3]
      )

    uses = rows(result, "use")
    assert length(uses) > 1
    assert uses |> Enum.flat_map(& &1.input["items"]) |> Enum.sort() == [1, 2, 3]
  end

  test "a batch keeps the earlier outputs its items share, and drops the rest" do
    result =
      run!(
        steps!(
          "shared",
          """
          [[steps]]
          name = "fetch"
          node = "fetch.toml"
          [[steps]]
          name = "each"
          node = "n.toml"
          after = ["fetch"]
          [[steps]]
          name = "chunk"
          node = "chunk.toml"
          after = ["each"]
          [[steps]]
          name = "say"
          node = "say.toml"
          after = ["chunk"]
          """,
          %{
            "fetch.toml" => fake_node(%{"return" => %{"list" => "{{ input }}"}}),
            "n.toml" => fake_node(%{"return" => "{{ steps.fetch.output.list }}"}),
            "chunk.toml" => batch_node(%{"size" => 10}),
            "say.toml" => fake_node(%{"return" => "{{ steps.fetch.output.list.0 }}"})
          }
        ),
        [[7, 8]]
      )

    # `fetch` ran once, so every item in the batch shares its output.
    assert [%{status: "ok", output: 7}] = rows(result, "say")
  end
end
