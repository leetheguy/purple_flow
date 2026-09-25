defmodule PurpleFlow.WorkflowHelpers do
  @moduledoc """
  Test helpers: write a workflow into a temp folder, load it, run it, and
  wait for it to finish.
  """

  import ExUnit.Assertions

  alias PurpleFlow.Workflow.Loader

  @doc """
  Writes `workflow_toml` plus `files` (`%{"a.toml" => contents}`) into a new
  temp folder. Returns the path to `workflow.toml`.
  """
  def write_workflow(workflow_toml, files \\ %{}) do
    dir = Path.join(System.tmp_dir!(), "purple_flow_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "workflow.toml"), workflow_toml)
    for {name, contents} <- files, do: File.write!(Path.join(dir, name), contents)
    Path.join(dir, "workflow.toml")
  end

  @doc "Writes and loads a workflow, failing the test if it has problems."
  def load_workflow!(workflow_toml, files \\ %{}) do
    case Loader.load(write_workflow(workflow_toml, files)) do
      {:ok, workflow} -> workflow
      {:error, problems} -> flunk("workflow didn't load:\n" <> Enum.join(problems, "\n"))
    end
  end

  @doc "A FakeNode node file with the given config."
  def fake_node(config \\ %{}) do
    TomlElixir.encode!(%{"module" => "PurpleFlow.Test.FakeNode", "config" => config})
  end

  @doc "Runs a workflow, waits for it to finish, returns `%{run: run, steps: rows}`."
  def run!(workflow, input, timeout \\ 5_000) do
    id = PurpleFlow.Id.generate()
    Phoenix.PubSub.subscribe(PurpleFlow.PubSub, PurpleFlow.topic(id))
    {:ok, ^id} = PurpleFlow.start_run(workflow, input, id: id)
    assert_receive {:run_finished, ^id, _status}, timeout
    PurpleFlow.Runs.get(id)
  end

  @doc "Rows for one step, sorted by item."
  def rows(%{steps: rows}, step),
    do: rows |> Enum.filter(&(&1.step == step)) |> Enum.sort_by(& &1.item)
end
