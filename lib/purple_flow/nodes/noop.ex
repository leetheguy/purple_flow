defmodule PurpleFlow.Nodes.Noop do
  @moduledoc """
  Does nothing: hands its input on unchanged.

      module = "PurpleFlow.Nodes.Noop"

  Useful as a named place for branches to meet, a placeholder while a
  workflow is being built, or a last step that makes a run's output
  obvious. No config.
  """

  @behaviour PurpleFlow.Node

  @impl true
  def execute(input, _config), do: {:ok, input}
end
