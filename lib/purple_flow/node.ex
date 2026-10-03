defmodule PurpleFlow.Node do
  @moduledoc """
  The one contract every node follows.

  A node is a module with an `execute` function: one input in, one output out.
  That's the whole interface. HTTP, Postgres, Code: all the same shape.

  The input is always one item. A list output splits into items, one
  execution each for the next steps; anything else, including an object
  holding a list, is one item. A node can also hand items on while it's
  still running, with `emit/2`. See `specs/120_flow.md`.

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
  Gets the config, the folder the node file is in, and the workflows folder
  (`root`). Returns the config to use from then on, or an error message. A
  node that reads a file named in its config resolves it with
  `PurpleFlow.Workflow.Paths.resolve/3`, so it can't leave `root`.
  """
  @callback prepare(config :: map(), node_dir :: String.t(), root :: String.t()) ::
              {:ok, map()} | {:error, String.t()}

  @optional_callbacks execute: 2, execute: 3, prepare: 3

  @doc """
  Hands one item on now, while the node is still running, instead of
  waiting for it to return (streaming, see `specs/150_streaming.md`). The
  item goes to the next steps right away, like a returned one: a list
  splits. Waits while a step after this one is full and set to wait.

  Call it only from the node's own execution. Outside one (a test calling
  `execute` directly), it sends `{:emit, value, route}` to the calling
  process instead.
  """
  @spec emit(term(), String.t() | nil) :: :ok
  def emit(value, route \\ nil) do
    case Process.get(:purple_flow_emit) do
      nil ->
        send(self(), {:emit, value, route})
        :ok

      emit ->
        emit.(value, route)
    end
  end

  @doc """
  Answers the webhook caller waiting on this run, if there is one and no
  step has answered yet: `reply` is `%{"status" => 200, "headers" => %{},
  "body" => ...}`. The run carries on. Returns `:ok` if the reply went to a
  caller, `:none` if nobody was waiting. The Respond node uses it.

  Outside a run (a test calling `execute` directly), it sends
  `{:respond, reply}` to the calling process instead and returns `:ok`.
  """
  @spec respond(map()) :: :ok | :none
  def respond(reply) do
    case Process.get(:purple_flow_respond) do
      nil ->
        send(self(), {:respond, reply})
        :ok

      respond ->
        respond.(reply)
    end
  end

  @doc """
  Like `respond/1`, but the answer is a stream: the webhook caller gets
  `status` and `headers` now, then each `respond_chunk/2` as it's sent, until
  `respond_done/1` (or the execution ends). The run carries on. Returns
  `{:ok, sink}` if a caller was waiting and nothing had answered yet,
  `:none` otherwise. The OpenAI Chat node uses it.

  Outside a run (a test calling `execute` directly), it sends
  `{:respond_stream, status, headers}` to the calling process, and the
  chunks and the end come to it as `{:respond_chunk, ref, data}` and
  `{:respond_done, ref}`.
  """
  @spec respond_stream(integer(), map()) :: {:ok, {pid(), reference()}} | :none
  def respond_stream(status, headers) do
    case Process.get(:purple_flow_respond_stream) do
      nil ->
        send(self(), {:respond_stream, status, headers})
        {:ok, {self(), make_ref()}}

      respond_stream ->
        respond_stream.(status, headers)
    end
  end

  @doc "Sends the next part of a streamed answer (see `respond_stream/2`)."
  @spec respond_chunk({pid(), reference()}, iodata()) :: :ok
  def respond_chunk({caller, ref}, data) do
    send(caller, {:respond_chunk, ref, data})
    :ok
  end

  @doc "Ends a streamed answer (see `respond_stream/2`)."
  @spec respond_done({pid(), reference()}) :: :ok
  def respond_done({caller, ref}) do
    send(caller, {:respond_done, ref})
    :ok
  end

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
