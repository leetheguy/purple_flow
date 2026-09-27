defmodule PurpleFlowWeb.AgentsController do
  @moduledoc """
  `GET /agents`: instructions for agents that come to edit workflows, so
  there's one link to hand them. It's `AGENTS.md` from the top of the
  workflows folder, as plain Markdown, with `BASE` replaced by this site's
  address. Public, since an agent needs it before it has a token; it
  holds only what's in that file. Without the file, a 404.
  """

  use PurpleFlowWeb, :controller

  def show(conn, _params) do
    case File.read(Path.join(PurpleFlow.Workflows.dir(), "AGENTS.md")) do
      {:ok, text} ->
        conn
        |> put_resp_content_type("text/markdown")
        |> send_resp(200, String.replace(text, ~r/\bBASE\b/, PurpleFlowWeb.Endpoint.url()))

      {:error, _} ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(
          404,
          "No agent instructions here yet: add AGENTS.md to the workflows folder."
        )
    end
  end
end
