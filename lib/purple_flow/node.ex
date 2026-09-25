defmodule PurpleFlow.Node do
  @moduledoc """
  The one contract every node follows.

  A node is a module with an `execute` function: one input in, one output out.
  That's the whole interface. HTTP, Postgres, Code: all the same shape.

      defmodule MyNode do
        @behaviour PurpleFlow.Node

        @impl true
        def execute(input, config) do
          {:ok, %{"hello" => input["name"]}}
        end
      end

  (A "behaviour" is Elixir's word for an interface: a list of functions a
  module promises to have.)
  """

  @type result ::
          {:ok, output :: term()}
          | {:ok, output :: term(), route :: String.t()}
          | {:error, reason :: term()}

  @doc """
  Does the node's work.

  - `input`: one JSON-shaped value (maps have string keys). When a step runs
    per item, this is one item.
  - `config`: the node file's `[config]` table, templates already filled in.

  Return `{:ok, output}`, `{:ok, output, "route"}` for if/else, or
  `{:error, reason}`. Raising an exception counts as an error.
  """
  @callback execute(input :: term(), config :: map()) :: result()

  @doc """
  Same as `execute/2`, plus `steps`: the outputs of this step's ancestors, as
  `%{"fetch" => %{"output" => ...}}`. Only nodes that need earlier outputs
  directly (like the Code node) implement this one.
  """
  @callback execute(input :: term(), config :: map(), steps :: map()) :: result()

  @doc """
  Optional. Runs once when the workflow loads, so mistakes show up early.
  Gets the config and the folder the node file is in. Returns the config to
  use from then on, or an error message.
  """
  @callback prepare(config :: map(), node_dir :: String.t()) ::
              {:ok, map()} | {:error, String.t()}

  @optional_callbacks execute: 2, execute: 3, prepare: 2

  @doc "True if `module` is a real module that says it's a `PurpleFlow.Node`."
  def node_module?(module) do
    with true <- Code.ensure_loaded?(module),
         behaviours =
           module.__info__(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten(),
         true <- __MODULE__ in behaviours do
      function_exported?(module, :execute, 2) or function_exported?(module, :execute, 3)
    else
      _ -> false
    end
  end
end
