defmodule PurpleFlowWeb.Plugs.FilesProxy do
  @moduledoc """
  `/fs/*`: the files service (dufs), passed through behind the app's own
  sign-in. dufs has no login of its own and no published port; the app is
  the only way in. See `specs/090_workflow_files.md`.

  Any one of these gets through:

  - a signed-in browser session (the `/files` page embeds dufs's UI)
  - `Authorization: Bearer <PURPLEFLOW_AGENT_TOKEN>`, for agents
  - the admin login as HTTP Basic auth, for WebDAV clients that only speak
    that (Finder, Windows, davfs2)

  Everything else is passed to dufs as is: every method (WebDAV included),
  the path, the query, and the body. The caller's `cookie` and
  `authorization` headers are not. dufs's own UI pages get the app's theme
  added (`priv/static/dufs/`).

  It sits in `PurpleFlowWeb.Endpoint` ahead of `Plug.Parsers`, so request
  bodies reach dufs untouched. The service's address is
  `config :purple_flow, :files_url` (`PURPLEFLOW_FILES_URL`). Without one
  (dev, test), `/fs/*` is a 404.
  """

  @behaviour Plug

  import Plug.Conn

  alias PurpleFlowWeb.Auth

  @prefix "fs"
  # Workflow files are small; this is only a ceiling.
  @max_body 50_000_000
  @hop_by_hop ~w(connection keep-alive proxy-connection transfer-encoding te trailer upgrade
                 content-length)
  # Never passed on to dufs. Without accept-encoding, its pages come back
  # uncompressed, so the theme can be added.
  @not_forwarded @hop_by_hop ++ ~w(host cookie authorization accept-encoding)
  @theme ~s(<link rel="stylesheet" href="/dufs/theme.css"><script src="/dufs/embed.js"></script>)

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%{path_info: [@prefix | _]} = conn, _opts) do
    conn = fetch_session(conn)

    cond do
      files_url() == nil ->
        conn |> send_resp(404, "The files service isn't set up.") |> halt()

      not authorized?(conn) ->
        conn |> refuse() |> halt()

      true ->
        conn |> forward() |> halt()
    end
  end

  def call(conn, _opts), do: conn

  defp files_url, do: Application.get_env(:purple_flow, :files_url)

  defp authorized?(conn) do
    Auth.agent?(conn) or Auth.basic_login?(conn) or
      (Auth.signed_in?(conn) and not cross_site?(conn))
  end

  # The session cookie is SameSite=Lax, which already keeps it off other
  # sites' writes; this refuses them outright as well.
  defp cross_site?(conn), do: get_req_header(conn, "sec-fetch-site") == ["cross-site"]

  # A browser gets the sign-in page (or a bare 401 from a script), never a
  # Basic auth popup. Anything else is told it can use Basic auth.
  defp refuse(conn) do
    case get_req_header(conn, "sec-fetch-mode") do
      ["navigate"] ->
        conn
        |> put_resp_header("location", PurpleFlowWeb.Plugs.RequireLogin.login_path(conn))
        |> send_resp(302, "")

      [_] ->
        send_resp(conn, 401, "")

      [] ->
        conn
        |> put_resp_header("www-authenticate", ~s(Basic realm="PurpleFlow files"))
        |> send_resp(401, "")
    end
  end

  defp forward(conn) do
    with {:ok, body, conn} <- read_all(conn, []),
         {:ok, response} <- request(conn, body) do
      respond(conn, response)
    else
      {:too_large, conn} -> send_resp(conn, 413, "")
      {:error, _reason} -> send_resp(conn, 502, "The files service didn't answer.")
    end
  end

  defp read_all(conn, acc, size \\ 0) do
    case read_body(conn) do
      {:ok, chunk, conn} when size + byte_size(chunk) <= @max_body ->
        {:ok, IO.iodata_to_binary([acc, chunk]), conn}

      {:more, chunk, conn} when size + byte_size(chunk) <= @max_body ->
        read_all(conn, [acc, chunk], size + byte_size(chunk))

      {:error, reason} ->
        {:error, reason}

      {_, _chunk, conn} ->
        {:too_large, conn}
    end
  end

  defp request(conn, body) do
    query = if conn.query_string == "", do: "", else: "?" <> conn.query_string

    [
      method: conn.method,
      url: files_url() <> conn.request_path <> query,
      headers: for({k, v} <- conn.req_headers, k not in @not_forwarded, do: {k, v}),
      body: body,
      # Passed through untouched: no redirects followed, nothing decoded.
      redirect: false,
      retry: false,
      decode_body: false,
      compressed: false,
      raw: true,
      receive_timeout: 60_000
    ]
    |> Keyword.merge(Application.get_env(:purple_flow, :files_req_options, []))
    |> Req.request()
  end

  defp respond(conn, %Req.Response{status: status, headers: headers, body: body}) do
    headers = for {k, values} <- headers, k not in @hop_by_hop, v <- values, do: {k, v}
    body = if dufs_page?(headers, body), do: add_theme(body), else: body

    conn
    |> merge_resp_headers(headers)
    |> send_resp(status, body)
  end

  defp dufs_page?(headers, body) do
    Enum.any?(headers, fn {k, v} ->
      k == "content-type" and String.starts_with?(v, "text/html")
    end) and
      String.contains?(body, ~s(<template id="index-data">))
  end

  defp add_theme(body), do: String.replace(body, "</head>", @theme <> "</head>", global: false)
end
