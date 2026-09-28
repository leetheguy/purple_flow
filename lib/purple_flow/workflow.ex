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
    max_upload: 100_000_000,
    cron: nil,
    steps: []
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          dir: String.t(),
          webhook: String.t() | nil,
          respond: :result | :immediately | :stream,
          auth: String.t() | nil,
          auth_header: String.t() | nil,
          max_upload: non_neg_integer(),
          cron: String.t() | nil,
          steps: [PurpleFlow.Workflow.Step.t()]
        }

  defmodule Step do
    @moduledoc """
    One step of a workflow: which node it runs, what feeds it, and how fast
    it drains its queue (see `specs/120_flow.md`).

    `ancestors` is every step you reach by following `after` backward. Those
    are the only earlier outputs this step is allowed to see.

    `timeout` is in milliseconds, `0` for no limit. `max_queue` is `nil` for
    no limit.
    """

    defstruct [
      :name,
      :module,
      :config,
      :node_path,
      :when,
      after: [],
      ancestors: [],
      timeout: 0,
      concurrency: 1_000,
      delay: 0,
      max_queue: nil,
      on_full: :wait,
      on_fail: :continue
    ]

    @type t :: %__MODULE__{
            name: String.t(),
            module: module(),
            config: map(),
            node_path: String.t(),
            when: String.t() | nil,
            after: [String.t()],
            ancestors: [String.t()],
            timeout: non_neg_integer(),
            concurrency: pos_integer(),
            delay: non_neg_integer(),
            max_queue: pos_integer() | nil,
            on_full: :wait | :overflow,
            on_fail: :continue | :end_run
          }
  end

  @doc "Finds a step by name."
  def step(%__MODULE__{steps: steps}, name), do: Enum.find(steps, &(&1.name == name))

  @doc "Steps with no `after`. They get the trigger's input."
  def first_steps(%__MODULE__{steps: steps}), do: Enum.filter(steps, &(&1.after == []))

  @doc "Steps that come right after `name`."
  def next_steps(%__MODULE__{steps: steps}, name), do: Enum.filter(steps, &(name in &1.after))

  @doc "True for a Batch step, which the run handles itself (`specs/140_batch.md`)."
  def batch?(%Step{module: module}), do: module == PurpleFlow.Nodes.Batch

  @doc "Steps that nothing else comes after. Their outputs are the run's output."
  def last_steps(%__MODULE__{steps: steps} = workflow) do
    Enum.filter(steps, &(next_steps(workflow, &1.name) == []))
  end
end
