defmodule PurpleFlowWeb.WorkflowStatusController do
  @moduledoc """
  `GET /api/workflows`: which workflows are loaded, which aren't, and why.
  For agents that edit workflow files and need to know whether their change
  took, without the admin login. See `specs/090_workflow_files.md`.

  Needs `Authorization: Bearer <PURPLEFLOW_AGENT_TOKEN>`. With no token
  configured, the route doesn't exist (404). The token grants this and
  nothing else.
  """

  use PurpleFlowWeb, :controller

  alias PurpleFlow.Workflows

  def index(conn, _params) do
    case System.get_env("PURPLEFLOW_AGENT_TOKEN") do
      token when token in [nil, ""] ->
        conn |> put_status(404) |> json(%{error: "not found"})

      token ->
        if authorized?(conn, token),
          do: json(conn, status()),
          else: conn |> put_status(401) |> json(%{error: "unauthorized"})
    end
  end

  defp authorized?(conn, token) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> given] -> Plug.Crypto.secure_compare(given, token)
      _ -> false
    end
  end

  defp status do
    %{reloaded_at: reloaded_at, folders: folders} = Workflows.status()
    {loaded, not_loaded} = Enum.split_with(folders, & &1.workflow)

    %{
      reloaded_at: reloaded_at,
      workflows:
        for entry <- loaded do
          %{
            name: entry.workflow.name,
            folder: entry.folder,
            webhook: entry.workflow.webhook,
            cron: entry.workflow.cron,
            loaded_at: entry.loaded_at,
            problems: entry.problems,
            running_older_version: entry.stale?
          }
        end,
      not_loaded: for(entry <- not_loaded, do: %{folder: entry.folder, problems: entry.problems})
    }
  end
end
