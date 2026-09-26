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
  Loads every `*/workflow.toml` under `dir`.

  Returns `{workflows, errors}`: loaded workflows by name, and a list of
  `{path, [problem]}` for the ones that didn't load. `dir` is the workflows
  folder: nothing a workflow names may be outside it.
  """
  def load_all(dir) do
    results =
      Path.join(dir, "*/workflow.toml")
      |> Path.wildcard()
      |> Enum.sort()
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
        webhook: get_in(toml, ["trigger", "webhook", "path"]),
        respond: respond_mode(get_in(toml, ["trigger", "webhook", "respond"])),
        auth: blank_to_nil(get_in(toml, ["trigger", "webhook", "auth"])),
        auth_header: auth_header(get_in(toml, ["trigger", "webhook", "auth_header"])),
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
         [name: name, module: module, config: config, node_path: node_path] ++ options
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

    with {:ok, run} <- run_mode(Map.get(raw, "run", "each"), label),
         {:ok, concurrency} <- concurrency(Map.get(raw, "concurrency", "concurrent"), label),
         {:ok, timeout} <- timeout(Map.get(raw, "timeout", 30), label),
         :ok <- check_when(raw["when"], after_, label) do
      {:ok,
       [after: after_, when: raw["when"], run: run, concurrency: concurrency, timeout: timeout]}
    end
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  # Header names are matched case-insensitively; Plug keeps them lowercase.
  defp auth_header(value) when is_binary(value), do: value |> String.downcase() |> blank_to_nil()
  defp auth_header(value), do: value

  defp respond_mode(nil), do: :result
  defp respond_mode("result"), do: :result
  defp respond_mode("immediately"), do: :immediately
  defp respond_mode(other), do: {:bad, other}

  defp run_mode("each", _), do: {:ok, :each}
  defp run_mode("all", _), do: {:ok, :all}

  defp run_mode(other, label),
    do: {:error, "#{label}: run must be \"each\" or \"all\", not #{inspect(other)}"}

  defp concurrency("concurrent", _), do: {:ok, 1_000}
  defp concurrency("sequential", _), do: {:ok, 1}
  defp concurrency(n, _) when is_integer(n) and n > 0, do: {:ok, n}

  defp concurrency(other, label),
    do:
      {:error,
       "#{label}: concurrency must be \"concurrent\", \"sequential\", or a number, not #{inspect(other)}"}

  defp timeout(seconds, _) when is_number(seconds) and seconds > 0,
    do: {:ok, round(seconds * 1000)}

  defp timeout(other, label),
    do: {:error, "#{label}: timeout must be a number of seconds, not #{inspect(other)}"}

  defp check_when(nil, _after, _label), do: :ok
  defp check_when(route, [_one], _label) when is_binary(route), do: :ok

  defp check_when(route, _after, label) when is_binary(route),
    do: {:error, "#{label}: `when` needs exactly one `after`"}

  defp check_when(other, _after, label),
    do: {:error, "#{label}: when must be a string, not #{inspect(other)}"}

  # -- whole-workflow checks --

  defp check_triggers(workflow),
    do: check_respond(workflow) ++ check_auth(workflow) ++ check_cron(workflow)

  defp check_respond(%Workflow{respond: {:bad, value}}) do
    [~s(webhook respond must be "result" or "immediately", not #{inspect(value)})]
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

    Enum.find_value(workflow.steps, [], fn step ->
      if cycle?(graph, step.name, MapSet.new()),
        do: ["steps loop back on themselves at \"#{step.name}\""]
    end)
  end

  defp cycle?(graph, name, seen) do
    if name in seen do
      true
    else
      seen = MapSet.put(seen, name)
      Enum.any?(Map.get(graph, name, []), &cycle?(graph, &1, seen))
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
