defmodule PurpleFlowWeb.Auth do
  @moduledoc """
  The one login: `PURPLEFLOW_ADMIN_USERNAME` and `PURPLEFLOW_ADMIN_PASSWORD`.

  People sign in once at `/login` and get a session cookie, which covers the
  whole UI, the LiveView socket, and the files service behind `/fs/`
  (`PurpleFlowWeb.Plugs.FilesProxy`). Agents use `PURPLEFLOW_AGENT_TOKEN`
  instead, which covers `/api/workflows` and `/fs/` and nothing else.

  Only enforced when both admin variables are set. In dev and test, where
  nothing sets them, the UI stays open. A real deployment (see
  `docker-compose.yml`) requires both.

  The session holds a token derived from the username and password, not a
  flag, so changing the password signs everyone out.
  """

  import Plug.Conn

  alias PurpleFlowWeb.LoginThrottle

  @session_key "signed_in"

  @doc "The admin login, or nil when sign-in isn't set up."
  def credentials do
    with username when username not in [nil, ""] <- System.get_env("PURPLEFLOW_ADMIN_USERNAME"),
         password when password not in [nil, ""] <- System.get_env("PURPLEFLOW_ADMIN_PASSWORD") do
      {username, password}
    else
      _ -> nil
    end
  end

  @doc "Whether signing in is required at all."
  def required?, do: credentials() != nil

  @doc "Whether `username` and `password` are the admin login. Constant-time."
  def valid_login?(username, password) when is_binary(username) and is_binary(password) do
    case credentials() do
      {expected_user, expected_pass} ->
        # Both compared, always, so timing doesn't say which one was wrong.
        user_ok = Plug.Crypto.secure_compare(username, expected_user)
        pass_ok = Plug.Crypto.secure_compare(password, expected_pass)
        user_ok and pass_ok

      nil ->
        false
    end
  end

  def valid_login?(_username, _password), do: false

  @doc """
  Checks a sign-in attempt from `conn`'s client, with lockout
  (`PurpleFlowWeb.LoginThrottle`): `:ok`, `:invalid`, or `:locked`. A locked
  out client is refused without checking the password.
  """
  def check_login(conn, username, password) do
    ip = client_ip(conn)

    cond do
      LoginThrottle.locked?(ip) ->
        :locked

      valid_login?(username, password) ->
        LoginThrottle.clear(ip)
        :ok

      true ->
        LoginThrottle.fail(ip)
        if LoginThrottle.locked?(ip), do: :locked, else: :invalid
    end
  end

  @doc """
  The client's IP address, for lockouts. Behind a reverse proxy every
  request comes from the proxy, so `config :purple_flow, :client_ip_header`
  (`PURPLEFLOW_CLIENT_IP_HEADER`, like `cf-connecting-ip` or
  `x-forwarded-for`) names the header the proxy puts the real address in;
  the last address in it is the one the proxy saw. Only for lockouts: the
  runner check (`PurpleFlowWeb.Plugs.RejectRunner`) never trusts a header.
  """
  def client_ip(conn) do
    with header when is_binary(header) <- Application.get_env(:purple_flow, :client_ip_header),
         [value | _] <- get_req_header(conn, header),
         address when address != "" <-
           value |> String.split(",") |> List.last() |> String.trim() do
      address
    else
      _ -> conn.remote_ip |> :inet.ntoa() |> to_string()
    end
  end

  @doc "Whether a session (a conn's, or a LiveView's session map) is signed in."
  def signed_in?(%Plug.Conn{} = conn), do: signed_in?(get_session(conn))

  def signed_in?(session) when is_map(session) do
    case {credentials(), session[@session_key]} do
      {nil, _} -> true
      {_, token} when is_binary(token) -> Plug.Crypto.secure_compare(token, session_token())
      _ -> false
    end
  end

  @doc "Signs the conn in: a fresh session holding the current login's token."
  def sign_in(conn) do
    conn
    |> configure_session(renew: true)
    |> clear_session()
    |> put_session(@session_key, session_token())
  end

  @doc "Signs the conn out."
  def sign_out(conn), do: configure_session(conn, drop: true)

  @doc "Whether the request carries `Authorization: Bearer <PURPLEFLOW_AGENT_TOKEN>`."
  def agent?(conn) do
    with token when token not in [nil, ""] <- System.get_env("PURPLEFLOW_AGENT_TOKEN"),
         ["Bearer " <> given] <- get_req_header(conn, "authorization") do
      Plug.Crypto.secure_compare(given, token)
    else
      _ -> false
    end
  end

  @doc "Whether the request carries the admin login as HTTP Basic auth (for WebDAV clients)."
  def basic_login?(conn) do
    case Plug.BasicAuth.parse_basic_auth(conn) do
      {username, password} -> check_login(conn, username, password) == :ok
      :error -> false
    end
  end

  @doc """
  Where to go after signing in: `path` if it's a path on this site, else `/`.
  Never another host, so `/login?return_to=` can't be used as a redirector.
  """
  def safe_return_to("/" <> rest = path) do
    if String.starts_with?(rest, ["/", "\\"]), do: "/", else: path
  end

  def safe_return_to(_), do: "/"

  # LiveView: checked when a LiveView mounts, over HTTP and over the socket.
  def on_mount(:require_login, _params, session, socket) do
    if signed_in?(session) do
      {:cont, socket}
    else
      {:halt, Phoenix.LiveView.redirect(socket, to: "/login")}
    end
  end

  defp session_token do
    {username, password} = credentials()
    # Keyed by the app's secret too: the cookie is signed, not encrypted, so
    # its token mustn't be something a password guess can be checked against.
    key = PurpleFlowWeb.Endpoint.config(:secret_key_base)

    :crypto.mac(:hmac, :sha256, key, "session\0" <> username <> "\0" <> password)
    |> Base.url_encode64(padding: false)
  end
end
