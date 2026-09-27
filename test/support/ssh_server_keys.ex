defmodule PurpleFlow.Test.SshServer.Keys do
  @moduledoc "The test SSH server's host key and the one user key it accepts."

  @behaviour :ssh_server_key_api

  @impl true
  def host_key(_algorithm, options), do: {:ok, own(options)[:host_key]}

  @impl true
  def is_auth_key(key, user, options), do: user == ~c"deploy" and key in own(options)[:user_keys]

  defp own(options), do: Keyword.get(options, :key_cb_private, [])
end
