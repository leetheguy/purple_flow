defmodule PurpleFlow.Workflow do
  @moduledoc """
  A loaded workflow: its name, triggers, and steps, as read from
  `workflows/<name>/workflow.toml`. See `PurpleFlow.Workflow.Loader`.
  """

  defstruct [
    :name,
    :dir,
    webhook: nil,
    respond: :result,
    auth: nil,
    auth_header: nil,
    cron: nil,
    steps: []
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          dir: String.t(),
          webhook: String.t() | nil,
          respond: :result | :immediately,
          auth: String.t() | nil,
          auth_header: String.t() | nil,
          cron: String.t() | nil,
          steps: [PurpleFlow.Workflow.Step.t()]
        }

  defmodule Step do
    @moduledoc """
    One step of a workflow: which node it runs, what it waits for, and how.

    `ancestors` is every step you reach by following `after` backward. Those
    are the only earlier outputs this step is allowed to see.
    """

    defstruct [
      :name,
      :module,
      :config,
      :node_path,
      :when,
      after: [],
      ancestors: [],
      timeout: 30_000,
      run: :each,
      concurrency: 1_000
    ]

    @type t :: %__MODULE__{
            name: String.t(),
            module: module(),
            config: map(),
            node_path: String.t(),
            when: String.t() | nil,
            after: [String.t()],
            ancestors: [String.t()],
            timeout: pos_integer(),
            run: :each | :all,
            concurrency: pos_integer()
          }
  end

  @doc "Finds a step by name."
  def step(%__MODULE__{steps: steps}, name), do: Enum.find(steps, &(&1.name == name))

  @doc "Steps with no `after`. They get the trigger's input."
  def first_steps(%__MODULE__{steps: steps}), do: Enum.filter(steps, &(&1.after == []))

  @doc "Steps that come right after `name`."
  def next_steps(%__MODULE__{steps: steps}, name), do: Enum.filter(steps, &(name in &1.after))

  @doc "Steps that nothing else comes after. Their outputs are the run's output."
  def last_steps(%__MODULE__{steps: steps} = workflow) do
    Enum.filter(steps, &(next_steps(workflow, &1.name) == []))
  end
end
