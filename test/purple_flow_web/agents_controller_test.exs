defmodule PurpleFlowWeb.AgentsControllerTest do
  use PurpleFlowWeb.ConnCase, async: false

  # Not async: points the workflows folder at a temp dir and sets the login.

  setup do
    dir = Path.join(System.tmp_dir!(), "pf_agents_#{System.unique_integer([:positive])}")
    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    original = Application.get_env(:purple_flow, :workflows_dir)
    Application.put_env(:purple_flow, :workflows_dir, dir)
    System.put_env("PURPLEFLOW_ADMIN_USERNAME", "admin")
    System.put_env("PURPLEFLOW_ADMIN_PASSWORD", "hunter2")

    on_exit(fn ->
      Application.put_env(:purple_flow, :workflows_dir, original)
      System.delete_env("PURPLEFLOW_ADMIN_USERNAME")
      System.delete_env("PURPLEFLOW_ADMIN_PASSWORD")
      File.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  test "serves AGENTS.md with no login, BASE filled in", %{conn: conn, dir: dir} do
    File.write!(Path.join(dir, "AGENTS.md"), "Files are at BASE/fs/. Not DATABASE_URL.")

    conn = get(conn, ~p"/agents")
    base = PurpleFlowWeb.Endpoint.url()
    assert response(conn, 200) == "Files are at #{base}/fs/. Not DATABASE_URL."
    assert get_resp_header(conn, "content-type") |> hd() =~ "text/markdown"
  end

  test "a 404 when there's no AGENTS.md", %{conn: conn} do
    assert conn |> get(~p"/agents") |> response(404) =~ "AGENTS.md"
  end
end
