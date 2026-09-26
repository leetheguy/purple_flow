defmodule PurpleFlowWeb.WebhookController do
  @moduledoc """
  Webhook trigger. `POST /hooks/sync-records` (or GET) starts the workflow
  whose `[trigger.webhook] path` is `"sync-records"`.

  The run's input is `%{"body" => ..., "query" => ..., "headers" => ...}`.

  By default the reply waits for the run and is the run's output: `200`
  with the output as JSON, or `500 {"error": ...}` if the run failed.
  The run ID is in the `x-run-id` header either way.

  With `respond = "immediately"` the reply comes right away:
  `202 {"run_id": "..."}`. Use that for workflows that take longer than
  about 100 seconds, since Cloudflare gives up on requests after that.

  Unknown path: 404.

  With `auth = "NAME"`, the caller must send `Authorization: Bearer <value>`,
  where `<value>` is credential NAME's value, or, with `auth_header`, that
  header holding the value itself. Otherwise: `401`, no body, no run. The
  token's header is never saved in the run's input. See `specs/040_triggers.md`.
  """

  use PurpleFlowWeb, :controller

  # The caller's own credentials shouldn't end up saved in run records.
  @dropped_headers ~w(authorization proxy-authorization cookie)

  def handle(conn, %{"path" => path}) do
    path = Enum.join(path, "/")

    case PurpleFlow.Workflows.find_webhook(path) do
      nil -> conn |> put_status(404) |> json(%{error: "no workflow listens on /hooks/#{path}"})
      workflow -> authorize(conn, workflow)
    end
  end

  defp authorize(conn, workflow) do
    if authorized?(conn, workflow),
      do: respond(conn, workflow, input(conn, workflow)),
      else: send_resp(conn, 401, "")
  end

  defp authorized?(_conn, %{auth: nil}), do: true

  # An unset or archived credential never falls back to open: `get` is nil,
  # and nothing matches.
  defp authorized?(conn, %{auth: name, auth_header: header}) do
    with expected when is_binary(expected) <- PurpleFlow.Credentials.get(name),
         [value] <- get_req_header(conn, header || "authorization"),
         {:ok, token} <- token(value, header) do
      Plug.Crypto.secure_compare(token, expected)
    else
      _ -> false
    end
  end

  # The default header carries `Bearer <token>`; a custom one, the token alone.
  defp token(value, nil) do
    case String.split(value, " ", parts: 2) do
      [scheme, token] -> if String.downcase(scheme) == "bearer", do: {:ok, token}, else: :error
      _ -> :error
    end
  end

  defp token(value, _header), do: {:ok, value}

  defp respond(conn, %{respond: :immediately} = workflow, input) do
    case PurpleFlow.run(workflow.name, input, trigger: "webhook") do
      {:ok, run_id} ->
        conn |> put_resp_header("x-run-id", run_id) |> put_status(202) |> json(%{run_id: run_id})

      {:error, message} ->
        conn |> put_status(500) |> json(%{error: message})
    end
  end

  defp respond(conn, workflow, input) do
    run_id = PurpleFlow.Id.generate()
    conn = put_resp_header(conn, "x-run-id", run_id)

    case PurpleFlow.run_and_wait(workflow.name, input, trigger: "webhook", id: run_id) do
      {:ok, output} -> conn |> put_status(200) |> json(output)
      {:error, message} -> conn |> put_status(500) |> json(%{error: message, run_id: run_id})
    end
  end

  defp input(conn, workflow) do
    dropped = [workflow.auth_header | @dropped_headers]

    %{
      "body" => body(conn.body_params),
      "query" => conn.query_params,
      "headers" => conn.req_headers |> Enum.reject(fn {k, _} -> k in dropped end) |> Map.new()
    }
  end

  # A JSON body that isn't an object (like a list) arrives wrapped as "_json".
  defp body(%{"_json" => value}), do: value
  defp body(%Plug.Conn.Unfetched{}), do: %{}
  defp body(params), do: params
end
