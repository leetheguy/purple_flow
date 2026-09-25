defmodule PurpleFlowWeb.WebhookController do
  @moduledoc """
  Webhook trigger. `POST /hooks/sync-records` (or GET) starts the workflow
  whose `[trigger.webhook] path` is `"sync-records"`.

  The run's input is `%{"body" => ..., "query" => ..., "headers" => ...}`.
  The reply comes right away: `202 {"run_id": "..."}`. Unknown path: 404.
  """

  use PurpleFlowWeb, :controller

  # The caller's own credentials shouldn't end up saved in run records.
  @dropped_headers ~w(authorization proxy-authorization cookie)

  def handle(conn, %{"path" => path}) do
    path = Enum.join(path, "/")

    with %PurpleFlow.Workflow{name: name} <- PurpleFlow.Workflows.find_webhook(path),
         {:ok, run_id} <- PurpleFlow.run(name, input(conn), trigger: "webhook") do
      conn |> put_status(202) |> json(%{run_id: run_id})
    else
      nil -> conn |> put_status(404) |> json(%{error: "no workflow listens on /hooks/#{path}"})
      {:error, message} -> conn |> put_status(500) |> json(%{error: message})
    end
  end

  defp input(conn) do
    %{
      "body" => body(conn.body_params),
      "query" => conn.query_params,
      "headers" =>
        conn.req_headers |> Enum.reject(fn {k, _} -> k in @dropped_headers end) |> Map.new()
    }
  end

  # A JSON body that isn't an object (like a list) arrives wrapped as "_json".
  defp body(%{"_json" => value}), do: value
  defp body(%Plug.Conn.Unfetched{}), do: %{}
  defp body(params), do: params
end
