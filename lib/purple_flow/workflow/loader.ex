defmodule PurpleFlow.Workflow.Loader do
  @moduledoc """
  Reads workflow folders from disk and checks them.

  Every problem is collected and reported together, so one load tells you
  everything that's wrong with a workflow. A workflow with problems isn't
  loaded; other workflows still are.
  """

  alias PurpleFlow.{Credentials, Template, Workflow}
  alias PurpleFlow.Workflow.{Paths, Step}

  @doc """
  Loads every workflow under `dir` (see `find/1`).

  Returns `{workflows, errors}`: loaded workflows by name, and a list of
  `{path, [problem]}` for the ones that didn't load. `dir` is the workflows
  folder: nothing a workflow names may be outside it.
  """
  def load_all(dir) do
    results =
      dir
      |> find()
      |> Enum.map(fn path -> {path, load(path, dir)} end)

    {loaded, errors} =
      Enum.reduce(results, {%{}, []}, fn
        {path, {:ok, wf}}, {loaded, errors} ->
          cond do
            Map.has_key?(loaded, wf.name) ->
              {loaded, [{path, ["another workflow is already named \"#{wf.name}\""]} | errors]}

            wf.webhook && Enum.any?(Map.values(loaded), &(&1.webhook == wf.webhook)) ->
              {loaded, [{path, ["webhook path \"#{wf.webhook}\" is already used"]} | errors]}

            true ->
              {Map.put(loaded, wf.name, wf), errors}
          end

        {path, {:error, problems}}, {loaded, errors} ->
          {loaded, [{path, problems} | errors]}
      end)

    {loaded, Enum.reverse(errors)}
  end

  @doc """
  Every `workflow.toml` under `dir`, sorted. A folder with one is a
  workflow, at any depth, and isn't looked inside. A folder without one is
  a group, and is. Dot-folders are skipped and symlinks aren't followed.
  """
  def find(dir), do: dir |> find_in() |> Enum.sort()

  # The folders directly in `dir`: a workflow's toml, or what's inside a group.
  defp find_in(dir) do
    for name <- ls(dir),
        not String.starts_with?(name, "."),
        path = Path.join(dir, name),
        match?({:ok, %{type: :directory}}, File.lstat(path)),
        toml <- workflow_or_group(path),
        do: toml
  end

  defp workflow_or_group(path) do
    toml = Path.join(path, "workflow.toml")
    if File.regular?(toml), do: [toml], else: find_in(path)
  end

  defp ls(dir) do
    case File.ls(dir) do
      {:ok, names} -> names
      {:error, _} -> []
    end
  end

  @doc """
  Loads one `workflow.toml`. Returns `{:ok, workflow}` or `{:error, [problem]}`.

  `root` is the workflows folder; it defaults to the folder the workflow's
  own folder is in.
  """
  def load(path, root \\ nil) do
    dir = Path.dirname(path)
    root = root || Path.dirname(dir)

    # The workflow's folder itself could be a symlink pointing out.
    with {:ok, _} <- inside(Path.basename(path), dir, root, "the workflow folder"),
         {:ok, toml} <- read_toml(path),
         {:ok, name} <- fetch_string(toml, ["workflow", "name"], "[workflow] name") do
      {steps, step_problems} = load_steps(toml, dir, root)

      workflow = %Workflow{
        name: name,
        dir: dir,
        comment: file_comment(path),
        webhook: get_in(toml, ["trigger", "webhook", "path"]),
        respond: respond_mode(get_in(toml, ["trigger", "webhook", "respond"])),
        auth: blank_to_nil(get_in(toml, ["trigger", "webhook", "auth"])),
        auth_header: auth_header(get_in(toml, ["trigger", "webhook", "auth_header"])),
        max_upload: get_in(toml, ["trigger", "webhook", "max_upload"]) || 100_000_000,
        cron: get_in(toml, ["trigger", "cron", "schedule"]),
        steps: steps
      }

      problems =
        step_problems ++
          check_triggers(workflow) ++
          check_after(workflow) ++
          check_cycles(workflow)

      # Placeholder checks need ancestors, which only make sense once the
      # graph itself is sound.
      with [] <- problems,
           workflow = add_ancestors(workflow),
           [] <- check_templates(workflow) do
        {:ok, workflow}
      else
        problems -> {:error, problems}
      end
    else
      {:error, problem} -> {:error, [problem]}
    end
  end

  # -- steps --

  defp load_steps(toml, dir, root) do
    raw_steps = Map.get(toml, "steps", [])

    {steps, problems} =
      Enum.map_reduce(raw_steps, [], fn raw, problems ->
        case load_step(raw, dir, root) do
          {:ok, step} -> {step, problems}
          {:error, step_problems} -> {nil, problems ++ step_problems}
        end
      end)

    names = for %{"name" => name} <- raw_steps, do: name
    dupes = names -- Enum.uniq(names)
    dupe_problems = for name <- Enum.uniq(dupes), do: "two steps are named \"#{name}\""
    empty = if raw_steps == [], do: ["no [[steps]] listed"], else: []

    {Enum.reject(steps, &is_nil/1), problems ++ dupe_problems ++ empty}
  end

  defp load_step(raw, dir, root) do
    name = raw["name"]
    label = "step \"#{name}\""

    with {:ok, name} <- fetch_string(raw, ["name"], "a step's name"),
         {:ok, node_file} <- fetch_string(raw, ["node"], "#{label}: node"),
         {:ok, node_path} <- inside(node_file, dir, root, "#{label}: node path"),
         {:ok, node} <- read_toml(node_path),
         {:ok, module} <- node_module(node, label),
         {:ok, config} <- prepare(module, Map.get(node, "config", %{}), node_path, root, label),
         {:ok, options} <- step_options(raw, label) do
      {:ok,
       struct!(
         Step,
         [name: name, module: module, config: config, node_path: node_path] ++
           [comment: file_comment(node_path)] ++ options
       )}
    else
      {:error, problem} -> {:error, [problem]}
    end
  end

  defp node_module(node, label) do
    with {:ok, name} <- fetch_string(node, ["module"], "#{label}: node file's module") do
      module = Module.concat([name])

      if PurpleFlow.Node.node_module?(module) do
        {:ok, module}
      else
        {:error, "#{label}: #{name} isn't a module that implements PurpleFlow.Node"}
      end
    end
  end

  defp prepare(module, config, node_path, root, label) do
    if function_exported?(module, :prepare, 3) do
      case module.prepare(config, Path.dirname(node_path), root) do
        {:ok, config} -> {:ok, config}
        {:error, message} -> {:error, "#{label}: #{message}"}
      end
    else
      {:ok, config}
    end
  end

  defp step_options(raw, label) do
    after_ = List.wrap(Map.get(raw, "after", []))

    with :ok <- removed(raw, label),
         {:ok, concurrency} <- concurrency(Map.get(raw, "concurrency", 1_000), label),
         {:ok, delay} <- whole(Map.get(raw, "delay", 0), 0, "delay", "milliseconds", label),
         {:ok, timeout} <- timeout(Map.get(raw, "timeout", 0), label),
         {:ok, max_queue} <- max_queue(Map.get(raw, "max_queue"), label),
         {:ok, on_full} <- on_full(Map.get(raw, "on_full"), max_queue, label),
         {:ok, on_fail} <- on_fail(Map.get(raw, "on_fail", "continue"), label),
         :ok <- check_when(raw["when"], after_, label) do
      {:ok,
       [
         after: after_,
         when: raw["when"],
         concurrency: concurrency,
         delay: delay,
         timeout: timeout,
         max_queue: max_queue,
         on_full: on_full,
         on_fail: on_fail
       ]}
    end
  end

  # Settings from before specs/120, with what to do instead.
  defp removed(%{"run" => _}, label),
    do:
      {:error,
       "#{label}: `run` was removed. Lists always split into items; to handle many items in one execution, put a Batch step before this one (specs/140)"}

  defp removed(_raw, _label), do: :ok

  defp concurrency(n, label),
    do: whole(n, 1, "concurrency", "a number, 1 for one at a time,", label)

  # A whole number of at least `min`.
  defp whole(n, min, _name, _unit, _label) when is_integer(n) and n >= min, do: {:ok, n}

  defp whole(other, min, name, unit, label),
    do: {:error, "#{label}: #{name} must be #{unit} #{min} or more, not #{inspect(other)}"}

  defp timeout(seconds, _) when is_number(seconds) and seconds >= 0,
    do: {:ok, round(seconds * 1000)}

  defp timeout(other, label),
    do:
      {:error,
       "#{label}: timeout must be a number of seconds (0 for no limit), not #{inspect(other)}"}

  defp max_queue(nil, _label), do: {:ok, nil}
  defp max_queue(n, label), do: whole(n, 1, "max_queue", "a number of items,", label)

  defp on_full(nil, _max_queue, _label), do: {:ok, :wait}
  defp on_full(_value, nil, label), do: {:error, "#{label}: on_full needs max_queue"}
  defp on_full("wait", _max_queue, _label), do: {:ok, :wait}
  defp on_full("overflow", _max_queue, _label), do: {:ok, :overflow}

  defp on_full(other, _max_queue, label),
    do: {:error, ~s(#{label}: on_full must be "wait" or "overflow", not #{inspect(other)})}

  defp on_fail("continue", _label), do: {:ok, :continue}
  defp on_fail("end_run", _label), do: {:ok, :end_run}

  defp on_fail(other, label),
    do: {:error, ~s(#{label}: on_fail must be "continue" or "end_run", not #{inspect(other)})}

  defp check_when(nil, _after, _label), do: :ok
  defp check_when(route, [_one], _label) when is_binary(route), do: :ok

  defp check_when(route, _after, label) when is_binary(route),
    do: {:error, "#{label}: `when` needs exactly one `after`"}

  defp check_when(other, _after, label),
    do: {:error, "#{label}: when must be a string, not #{inspect(other)}"}

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  # Header names are matched case-insensitively; Plug keeps them lowercase.
  defp auth_header(value) when is_binary(value), do: value |> String.downcase() |> blank_to_nil()
  defp auth_header(value), do: value

  defp respond_mode(nil), do: :result
  defp respond_mode("result"), do: :result
  defp respond_mode("immediately"), do: :immediately
  defp respond_mode("stream"), do: :stream
  defp respond_mode(other), do: {:bad, other}

  # -- whole-workflow checks --

  defp check_triggers(workflow),
    do:
      check_respond(workflow) ++
        check_auth(workflow) ++ check_max_upload(workflow) ++ check_cron(workflow)

  defp check_max_upload(%Workflow{max_upload: n}) when is_integer(n) and n >= 0, do: []

  defp check_max_upload(%Workflow{max_upload: n}),
    do: [
      "webhook max_upload must be a number of bytes, 0 or more (0 = no limit), not #{inspect(n)}"
    ]

  defp check_respond(%Workflow{respond: {:bad, value}}) do
    [~s(webhook respond must be "result", "immediately", or "stream", not #{inspect(value)})]
  end

  defp check_respond(_workflow), do: []

  defp check_auth(%Workflow{auth: nil, auth_header: nil}), do: []

  defp check_auth(%Workflow{auth: nil}),
    do: ["webhook auth_header needs auth, the credential to check it against"]

  defp check_auth(%Workflow{auth: auth}) when not is_binary(auth),
    do: ["webhook auth must be a credential name, not #{inspect(auth)}"]

  defp check_auth(%Workflow{auth_header: header}) when not (is_nil(header) or is_binary(header)),
    do: ["webhook auth_header must be a header name, not #{inspect(header)}"]

  defp check_auth(%Workflow{auth: name}) do
    if Credentials.set?(name),
      do: [],
      else: ["webhook auth credential #{name} isn't set (set it at /credentials)"]
  end

  defp check_cron(%Workflow{cron: nil}), do: []

  defp check_cron(%Workflow{cron: schedule}) do
    case Crontab.CronExpression.Parser.parse(schedule) do
      {:ok, _} -> []
      {:error, _} -> ["cron schedule \"#{schedule}\" isn't valid"]
    end
  end

  defp check_after(workflow) do
    names = MapSet.new(workflow.steps, & &1.name)

    for step <- workflow.steps, parent <- step.after, parent not in names do
      "step \"#{step.name}\": after \"#{parent}\", but there's no step with that name"
    end
  end

  # A cycle means some step would (eventually) wait for itself.
  defp check_cycles(workflow) do
    graph = Map.new(workflow.steps, &{&1.name, &1.after})

    Enum.reduce_while(workflow.steps, {[], MapSet.new()}, fn step, {[], clear} ->
      case visit(graph, step.name, MapSet.new(), clear) do
        {:ok, clear} -> {:cont, {[], clear}}
        :cycle -> {:halt, {["steps loop back on themselves at \"#{step.name}\""], clear}}
      end
    end)
    |> elem(0)
  end

  # Walks `after` backward from `name`. `path` is the steps on the way here;
  # `clear` is every step already walked with no loop behind it, so it isn't
  # walked again. Without `clear`, every path is walked separately, and a
  # chain of branches that meet again has 2^n of them.
  defp visit(graph, name, path, clear) do
    cond do
      name in clear ->
        {:ok, clear}

      name in path ->
        :cycle

      true ->
        path = MapSet.put(path, name)

        Enum.reduce_while(Map.get(graph, name, []), {:ok, clear}, fn parent, {:ok, clear} ->
          case visit(graph, parent, path, clear) do
            {:ok, clear} -> {:cont, {:ok, clear}}
            :cycle -> {:halt, :cycle}
          end
        end)
        |> case do
          {:ok, clear} -> {:ok, MapSet.put(clear, name)}
          :cycle -> :cycle
        end
    end
  end

  defp add_ancestors(workflow) do
    graph = Map.new(workflow.steps, &{&1.name, &1.after})

    steps =
      Enum.map(workflow.steps, fn step ->
        %{step | ancestors: ancestors(graph, step.after, MapSet.new()) |> Enum.sort()}
      end)

    %{workflow | steps: steps}
  end

  defp ancestors(_graph, [], seen), do: seen

  defp ancestors(graph, [name | rest], seen) do
    if name in seen do
      ancestors(graph, rest, seen)
    else
      ancestors(graph, Map.get(graph, name, []) ++ rest, MapSet.put(seen, name))
    end
  end

  # Placeholders are checked now, so typos fail at load time, not mid-run.
  defp check_templates(workflow) do
    for step <- workflow.steps,
        ref <- Template.refs(step.config),
        problem = template_problem(step, ref),
        problem do
      "step \"#{step.name}\": #{problem}"
    end
  end

  defp template_problem(_step, {:creds, name}) do
    if not Credentials.set?(name), do: "credential #{name} isn't set (set it at /credentials)"
  end

  defp template_problem(step, {:steps, name, _}) do
    if name not in step.ancestors,
      do: "{{ steps.#{name}... }}: \"#{name}\" isn't an ancestor of this step"
  end

  defp template_problem(_step, {:input, _}), do: nil
  defp template_problem(_step, {:bad, path}), do: "don't know what {{ #{path} }} means"

  @doc """
  The comment at the top of a TOML file's text: the `#` lines before the
  first line of anything else, without their `#` (and one space after it).
  Blank lines between them are kept as blank lines. `nil` if there are none.
  """
  def leading_comment(text) do
    text
    |> String.split(~r/\r?\n/)
    |> Enum.take_while(&(String.trim(&1) == "" or String.starts_with?(String.trim(&1), "#")))
    |> Enum.map(&(&1 |> String.trim() |> String.replace(~r/^#+ ?/, "") |> String.trim_trailing()))
    |> Enum.join("\n")
    |> String.trim()
    |> case do
      "" -> nil
      comment -> comment
    end
  end

  defp file_comment(path) do
    case File.read(path) do
      {:ok, text} -> leading_comment(text)
      {:error, _} -> nil
    end
  end

  # -- small helpers --

  defp read_toml(path) do
    with {:ok, text} <- read_file(path) do
      case TomlElixir.decode(text) do
        {:ok, toml} ->
          {:ok, toml}

        {:error, error} ->
          {:error, "#{relative(path)} isn't valid TOML: #{Exception.message(error)}"}
      end
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, text} -> {:ok, text}
      {:error, _} -> {:error, "can't read #{relative(path)}"}
    end
  end

  defp fetch_string(map, keys, label) do
    case get_in(map, keys) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, "#{label} is missing"}
    end
  end

  defp inside(name, from_dir, root, label) do
    case Paths.resolve(name, from_dir, root) do
      {:ok, path} -> {:ok, path}
      :error -> {:error, "#{label} leaves the workflows folder"}
    end
  end

  defp relative(path), do: Path.relative_to_cwd(path)
end
