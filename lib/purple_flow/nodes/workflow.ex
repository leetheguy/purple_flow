defmodule PurpleFlow.Nodes.Workflow do
  @moduledoc """
  Runs another workflow and returns its output.

      module = "PurpleFlow.Nodes.Workflow"

      [config]
      workflow = "enrich_contact"

  The other workflow gets this node's input as its trigger input. This node
  waits for it to finish; the step's `timeout` covers the wait. If the other
  workflow fails, this node fails.

  See [specs/020](specs/020_nodes.md), [specs/120](specs/120_flow.md).
  """

  @behaviour PurpleFlow.Node

  @impl true
  def execute(input, config) do
    PurpleFlow.run_and_wait(Map.fetch!(config, "workflow"), input, trigger: "workflow")
  end
end
