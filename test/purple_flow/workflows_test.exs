defmodule PurpleFlow.WorkflowsTest do
  # Not async: the credentials test needs the watcher's own process to use
  # the database, which takes the sandbox's shared mode.
  use PurpleFlow.DataCase, async: false

  # Every broken save the tests make is logged as an error.
  @moduletag :capture_log

  import PurpleFlow.WorkflowHelpers

  alias PurpleFlow.{Credentials, Workflows}

  setup do
    root = Path.join(System.tmp_dir!(), "pf_watch_#{System.unique_integer([:positive])}")
    # unique_integer repeats across test runs, and /tmp doesn't get cleared.
    File.rm_rf!(root)
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  defp start(root, opts \\ []) do
    name = :"workflows_#{System.unique_integer([:positive])}"

    opts =
      Keyword.merge(
        [name: name, dir: root, interval: :manual, credentials: false, cron: false],
        opts
      )

    start_supervised!({Workflows, opts}, id: name)
    name
  end

  # Writes root/<folder>/workflow.toml plus a fake node file.
  defp put(root, folder, name, extra \\ "") do
    dir = Path.join(root, folder)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "n.toml"), fake_node())

    File.write!(Path.join(dir, "workflow.toml"), """
    [workflow]
    name = "#{name}"
    #{extra}

    [[steps]]
    name = "a"
    node = "n.toml"
    """)
  end

  defp names(server), do: server |> Workflows.list() |> Enum.map(& &1.name)

  defp entry(server, folder),
    do: Enum.find(Workflows.status(server).folders, &(&1.folder == folder))

  test "a change loads once it has held still for a tick, not before", %{root: root} do
    server = start(root)
    assert names(server) == []

    put(root, "one", "one")
    :ok = Workflows.tick(server)
    assert names(server) == [], "loaded on the tick that first saw the change"

    :ok = Workflows.tick(server)
    assert names(server) == ["one"]
  end

  test "a change that keeps changing waits until it stops", %{root: root} do
    server = start(root)

    put(root, "one", "one")
    :ok = Workflows.tick(server)
    put(root, "two", "two")
    :ok = Workflows.tick(server)
    assert names(server) == []

    :ok = Workflows.tick(server)
    assert names(server) == ["one", "two"]
  end

  test "nothing reloads when nothing changed, and dot-folders are ignored", %{root: root} do
    put(root, "one", "one")
    server = start(root)
    reloaded_at = Workflows.status(server).reloaded_at

    File.mkdir_p!(Path.join(root, ".git"))
    File.write!(Path.join([root, ".git", "HEAD"]), "ref: refs/heads/main")
    :ok = Workflows.tick(server)
    :ok = Workflows.tick(server)

    assert Workflows.status(server).reloaded_at == reloaded_at
  end

  test "a broken save keeps the old version running and says so", %{root: root} do
    put(root, "one", "one")
    server = start(root)
    %{workflow: old, loaded_at: loaded_at} = entry(server, "one")

    File.write!(Path.join([root, "one", "workflow.toml"]), "[workflow\nname = ")
    :ok = Workflows.reload(server)

    assert %{workflow: ^old, loaded_at: ^loaded_at, stale?: true, problems: [problem]} =
             entry(server, "one")

    assert problem =~ "isn't valid TOML"
    assert {:ok, ^old} = Workflows.fetch(server, "one")
    assert [{_, [^problem]}] = Workflows.errors(server)

    put(root, "one", "one")
    :ok = Workflows.reload(server)
    assert %{stale?: false, problems: []} = entry(server, "one")
  end

  test "a folder that never loaded is listed with its problems", %{root: root} do
    File.mkdir_p!(Path.join(root, "draft"))
    File.write!(Path.join([root, "draft", "workflow.toml"]), "[workflow]")
    server = start(root)

    assert %{workflow: nil, stale?: false, problems: ["[workflow] name is missing"]} =
             entry(server, "draft")
  end

  test "an edit that takes another workflow's name or webhook is refused", %{root: root} do
    put(root, "a", "alpha", ~s([trigger.webhook]\npath = "alpha"))
    put(root, "b", "beta", ~s([trigger.webhook]\npath = "beta"))
    server = start(root)

    # "b" sorts after "a", but "a" is the one that changed, so "a" loses.
    put(root, "a", "beta")
    :ok = Workflows.reload(server)
    assert %{workflow: %{name: "alpha"}, stale?: true, problems: [problem]} = entry(server, "a")
    assert problem =~ ~s(already named "beta")
    assert %{workflow: %{name: "beta"}, problems: []} = entry(server, "b")

    put(root, "a", "alpha", ~s([trigger.webhook]\npath = "beta"))
    :ok = Workflows.reload(server)
    assert %{workflow: %{webhook: "alpha"}, problems: [problem]} = entry(server, "a")
    assert problem =~ ~s(webhook path "beta" is already used)
  end

  test "unchanged workflows keep their loaded_at across reloads", %{root: root} do
    put(root, "one", "one")
    server = start(root)
    %{loaded_at: loaded_at} = entry(server, "one")

    put(root, "two", "two")
    :ok = Workflows.reload(server)

    assert %{loaded_at: ^loaded_at} = entry(server, "one")
    assert Workflows.status(server).reloaded_at != loaded_at
  end

  describe "cron" do
    defp job(name), do: PurpleFlow.Scheduler.find_job(String.to_atom("workflow:" <> name))

    test "jobs follow the folder, and unchanged ones aren't re-registered", %{root: root} do
      name = "cron_#{System.unique_integer([:positive])}"
      put(root, "c", name, ~s([trigger.cron]\nschedule = "0 * * * *"))
      server = start(root, cron: true)
      assert job(name)

      # Taken away behind the watcher's back: an unchanged schedule mustn't
      # bring it back, because it isn't registered again.
      PurpleFlow.Scheduler.delete_job(String.to_atom("workflow:" <> name))
      put(root, "other", "other_#{name}")
      :ok = Workflows.reload(server)
      refute job(name)

      put(root, "c", name, ~s([trigger.cron]\nschedule = "5 * * * *"))
      :ok = Workflows.reload(server)
      assert job(name).schedule == Crontab.CronExpression.Parser.parse!("5 * * * *")

      File.rm_rf!(Path.join(root, "c"))
      :ok = Workflows.reload(server)
      refute job(name)
      assert entry(server, "c") == nil
    end
  end

  test "setting a missing credential makes its workflow load", %{root: root} do
    cred = "WATCH_TOKEN_#{System.unique_integer([:positive])}"
    put(root, "guarded", "guarded", ~s([trigger.webhook]\npath = "guarded"\nauth = "#{cred}"))
    server = start(root, credentials: true)
    assert %{workflow: nil, problems: [_]} = entry(server, "guarded")

    {:ok, %{id: id}} = Credentials.create(cred, "for the watcher test")
    {:ok, _} = Credentials.update(id, %{key: "s3cret"})

    # The broadcast reached the watcher before this call did.
    assert %{workflow: %{name: "guarded"}, problems: []} = entry(server, "guarded")
  end
end
