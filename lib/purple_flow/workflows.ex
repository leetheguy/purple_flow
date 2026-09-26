defmodule PurpleFlow.Workflows do
  @moduledoc """
  Holds every loaded workflow in memory, and keeps it in step with the
  workflows folder. See `specs/090_workflow_files.md`.

  Once a second (a "tick") it fingerprints every file in the folder. When
  the fingerprint has changed and then held still for one full tick, so a
  half-written set of files is never loaded, it reloads. It also reloads
  whenever a credential changes, since a workflow can fail only because a
  `creds.NAME` it uses wasn't set.

  Reloading goes folder by folder. A folder that loads replaces what was
  running. A folder that fails keeps running its last good version, with
  the problems recorded next to it. Runs already going hold their own copy
  of the workflow and finish on it.

  The app starts one of these under its own name. Tests start their own on
  a temporary folder, with `interval: :manual`, and call `tick/1`.
  """

  use GenServer
  require Logger

  alias PurpleFlow.Workflow.Loader

  # Bigger files are fingerprinted by size and modified time only.
  @hash_limit 1_000_000

  @doc """
  Options: `:name` (default this module), `:dir` (default `dir/0`, read
  again at every reload),
  `:interval` in ms or `:manual` (default from the `:workflows_watch`
  config, 1,000), `:credentials` to reload on credential changes, and
  `:cron` to register cron jobs (both default true).
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "All loaded workflows, sorted by name."
  def list(server \\ __MODULE__), do: GenServer.call(server, :list)

  @doc "`{:ok, workflow}` or `{:error, message}`."
  def fetch(server \\ __MODULE__, name) do
    case GenServer.call(server, {:get, name}) do
      nil -> {:error, "no workflow named #{inspect(name)}"}
      workflow -> {:ok, workflow}
    end
  end

  @doc "The workflow whose webhook path is `path`, or `nil`."
  def find_webhook(server \\ __MODULE__, path), do: GenServer.call(server, {:webhook, path})

  @doc """
  Every folder with problems, as `[{path, [problem]}]`: ones that didn't
  load, and ones still running an older version.
  """
  def errors(server \\ __MODULE__), do: GenServer.call(server, :errors)

  @doc """
  The whole picture: `%{reloaded_at: time, folders: [folder]}`, one entry per
  workflow folder, sorted. Each has `folder`, `path`, `workflow` (the running
  version, or `nil`), `loaded_at`, `problems`, and `stale?` (true when the
  folder's latest edit failed and an older version is still running).
  """
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @doc "Reads the workflows folder again, right now."
  def reload(server \\ __MODULE__), do: GenServer.call(server, :reload)

  @doc "Checks the folder for changes once, as the timer does."
  def tick(server \\ __MODULE__), do: GenServer.call(server, :tick)

  @doc "The folder workflows are read from."
  def dir, do: Application.get_env(:purple_flow, :workflows_dir, "workflows")

  # -- server --

  @impl true
  def init(opts) do
    watch = Application.get_env(:purple_flow, :workflows_watch, [])

    state = %{
      dir: Keyword.get(opts, :dir),
      interval: Keyword.get(opts, :interval, Keyword.get(watch, :interval, 1_000)),
      cron?: Keyword.get(opts, :cron, true),
      folders: %{},
      jobs: %{},
      reloaded_at: nil,
      loaded_fingerprint: nil,
      pending_fingerprint: nil
    }

    credentials? = Keyword.get(opts, :credentials, Keyword.get(watch, :credentials, true))

    if credentials?,
      do: Phoenix.PubSub.subscribe(PurpleFlow.PubSub, PurpleFlow.Credentials.topic())

    schedule_tick(state)
    {:ok, reload_now(state)}
  end

  @impl true
  def handle_call(:list, _from, state) do
    {:reply, state |> running() |> Enum.sort_by(& &1.name), state}
  end

  def handle_call({:get, name}, _from, state) do
    {:reply, Enum.find(running(state), &(&1.name == name)), state}
  end

  def handle_call({:webhook, path}, _from, state) do
    {:reply, Enum.find(running(state), &(&1.webhook == path)), state}
  end

  def handle_call(:errors, _from, state) do
    errors = for entry <- sorted(state), entry.problems != [], do: {entry.path, entry.problems}
    {:reply, errors, state}
  end

  def handle_call(:status, _from, state) do
    {:reply, %{reloaded_at: state.reloaded_at, folders: sorted(state)}, state}
  end

  def handle_call(:reload, _from, state), do: {:reply, :ok, reload_now(state)}
  def handle_call(:tick, _from, state), do: {:reply, :ok, check(state)}

  @impl true
  def handle_info(:tick, state) do
    state = check(state)
    schedule_tick(state)
    {:noreply, state}
  end

  def handle_info(:credentials_changed, state), do: {:noreply, reload_now(state)}

  defp schedule_tick(%{interval: :manual}), do: :ok
  defp schedule_tick(%{interval: ms}), do: Process.send_after(self(), :tick, ms)

  # -- watching --

  # Reload only once a change has held still for a whole tick.
  defp check(state) do
    fingerprint = fingerprint(folder_dir(state))

    cond do
      fingerprint == state.loaded_fingerprint -> %{state | pending_fingerprint: nil}
      fingerprint == state.pending_fingerprint -> reload(state, fingerprint)
      true -> %{state | pending_fingerprint: fingerprint}
    end
  end

  defp reload_now(state), do: reload(state, fingerprint(folder_dir(state)))
  defp folder_dir(state), do: state.dir || dir()

  # Every file under `dir`, with its size, modified time, and (for small
  # files) a hash of its contents. Walked by hand so dot-folders like `.git`
  # are skipped and symlinks are never followed (a link loop can't hang it).
  defp fingerprint(dir), do: dir |> walk() |> Map.new()

  defp walk(path) do
    case File.ls(path) do
      {:ok, names} ->
        for name <- names,
            not String.starts_with?(name, "."),
            entry <- walk_entry(Path.join(path, name)),
            do: entry

      {:error, _} ->
        []
    end
  end

  defp walk_entry(path) do
    case File.lstat(path, time: :posix) do
      {:ok, %{type: :directory}} ->
        walk(path)

      {:ok, %{type: :regular, size: size, mtime: mtime}} ->
        [{path, {size, mtime, hash(path, size)}}]

      {:ok, %{type: :symlink}} ->
        [{path, File.read_link(path)}]

      _ ->
        []
    end
  end

  defp hash(_path, size) when size > @hash_limit, do: nil

  defp hash(path, _size) do
    case File.read(path) do
      {:ok, contents} -> :erlang.md5(contents)
      {:error, _} -> nil
    end
  end

  # -- reloading --

  defp reload(state, fingerprint) do
    now = DateTime.utc_now()
    dir = folder_dir(state)

    results =
      Path.join(dir, "*/workflow.toml")
      |> Path.wildcard()
      |> Map.new(fn path -> {folder(path), {path, Loader.load(path, dir)}} end)

    folders = settle(results, state.folders, now)
    log_problems(folders, state.folders)

    %{
      state
      | folders: folders,
        jobs: if(state.cron?, do: sync_cron(folders, state.jobs), else: state.jobs),
        reloaded_at: now,
        loaded_fingerprint: fingerprint,
        pending_fingerprint: nil
    }
  end

  # Decides what each folder runs. Two folders can't claim the same name or
  # webhook path. Folders keeping the claims they already had go first, so
  # an edit that would take another workflow's name or path is the one
  # refused, and the folder keeps running its old version.
  defp settle(results, previous, now) do
    {keeping, changing} =
      results
      |> Enum.sort()
      |> Enum.split_with(fn {folder, {_path, result}} ->
        keeps_claims?(result, previous[folder])
      end)

    {folders, _claims} =
      Enum.reduce(keeping ++ changing, {%{}, %{names: MapSet.new(), hooks: MapSet.new()}}, fn
        {folder, {path, result}}, {acc, claims} ->
          entry = entry(folder, path, result, previous[folder], claims, now)
          {Map.put(acc, folder, entry), claim(claims, entry.workflow)}
      end)

    folders
  end

  defp keeps_claims?({:ok, wf}, %{workflow: %{} = old}), do: claims(wf) == claims(old)
  defp keeps_claims?({:error, _}, %{workflow: %{}}), do: true
  defp keeps_claims?(_result, _previous), do: false

  defp claims(wf), do: {wf.name, wf.webhook}

  defp entry(folder, path, {:ok, wf}, previous, claims, now) do
    case collision(wf, claims) do
      nil ->
        loaded_at = if previous && previous.workflow == wf, do: previous.loaded_at, else: now

        %{
          folder: folder,
          path: path,
          workflow: wf,
          loaded_at: loaded_at,
          problems: [],
          stale?: false
        }

      problem ->
        fall_back(folder, path, [problem], previous, claims)
    end
  end

  defp entry(folder, path, {:error, problems}, previous, claims, _now),
    do: fall_back(folder, path, problems, previous, claims)

  # The latest edit didn't load: keep the running version, if there is one
  # and it still doesn't clash with anything.
  defp fall_back(folder, path, problems, %{workflow: %{} = old} = previous, claims) do
    if collision(old, claims) do
      %{
        folder: folder,
        path: path,
        workflow: nil,
        loaded_at: nil,
        problems: problems,
        stale?: false
      }
    else
      %{previous | path: path, problems: problems, stale?: true}
    end
  end

  defp fall_back(folder, path, problems, _previous, _claims),
    do: %{
      folder: folder,
      path: path,
      workflow: nil,
      loaded_at: nil,
      problems: problems,
      stale?: false
    }

  defp collision(wf, claims) do
    cond do
      wf.name in claims.names -> "another workflow is already named \"#{wf.name}\""
      wf.webhook && wf.webhook in claims.hooks -> "webhook path \"#{wf.webhook}\" is already used"
      true -> nil
    end
  end

  defp claim(claims, nil), do: claims

  defp claim(claims, wf) do
    hooks = if wf.webhook, do: MapSet.put(claims.hooks, wf.webhook), else: claims.hooks
    %{names: MapSet.put(claims.names, wf.name), hooks: hooks}
  end

  # Logs only what's new, since a reload can happen every second.
  defp log_problems(folders, previous) do
    for {folder, entry} <- folders,
        entry.problems != [],
        entry.problems != get_in(previous, [folder, :problems]) do
      verb =
        if entry.stale?, do: "still running its older version; latest edit", else: "not loaded"

      Logger.error(
        "workflow #{Path.relative_to_cwd(entry.path)} #{verb}:\n  - " <>
          Enum.join(entry.problems, "\n  - ")
      )
    end
  end

  # Adds, replaces, and removes only the cron jobs whose schedules changed.
  defp sync_cron(folders, jobs) do
    wanted =
      for %{workflow: %{cron: cron} = wf} <- Map.values(folders),
          cron,
          into: %{},
          do: {wf.name, cron}

    for {name, _} <- jobs,
        not Map.has_key?(wanted, name),
        do: PurpleFlow.Scheduler.delete_job(job_name(name))

    for {name, schedule} <- wanted, jobs[name] != schedule do
      PurpleFlow.Scheduler.delete_job(job_name(name))
      add_job(name, schedule)
    end

    wanted
  end

  defp add_job(name, schedule) do
    PurpleFlow.Scheduler.new_job()
    |> Quantum.Job.set_name(job_name(name))
    |> Quantum.Job.set_schedule(Crontab.CronExpression.Parser.parse!(schedule))
    |> Quantum.Job.set_task(fn ->
      PurpleFlow.run(name, %{"scheduled_at" => DateTime.to_iso8601(DateTime.utc_now())},
        trigger: "cron"
      )
    end)
    |> PurpleFlow.Scheduler.add_job()
  end

  defp job_name(name), do: String.to_atom("workflow:" <> name)

  # -- helpers --

  defp folder(path), do: path |> Path.dirname() |> Path.basename()
  defp running(state), do: for(%{workflow: %{} = wf} <- Map.values(state.folders), do: wf)
  defp sorted(state), do: state.folders |> Map.values() |> Enum.sort_by(& &1.folder)
end
