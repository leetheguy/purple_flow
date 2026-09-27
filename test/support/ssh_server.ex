defmodule PurpleFlow.Test.SshServer do
  @moduledoc """
  A real SSH server on localhost for the SSH node's tests, with Erlang's
  `:ssh` daemon. It doesn't run commands: `handler` gets each command and
  its stdin and returns what to do, as a list of

  - `{:out, data}` / `{:err, data}`: write to stdout / stderr
  - `{:sleep, ms}`
  - `{:wait}`: send `{:waiting, pid}` to the test, and carry on when it sends `:go` to `pid`
  - `{:exit, status}` (else it exits 0)
  - `{:signal, name}`: end killed by a signal instead
  - `{:hang}`: never finish

  and each channel sends `{:ssh_channel_closed, command}` to the test when
  it ends.
  """

  @doc """
  Starts one. Returns `%{port:, host_key_fingerprint:, user_key:,
  rsa_user_key:}`. It lets `"deploy"` in with the password `"hunter2"` or
  either private key: `user_key` is ed25519 in OpenSSH's format (what
  `ssh-keygen` writes), `rsa_user_key` is RSA in the older PEM format.
  """
  def start!(handler) do
    {:ok, _} = Application.ensure_all_started(:ssh)
    host_key = :public_key.generate_key({:namedCurve, :ed25519})
    user_key = :public_key.generate_key({:namedCurve, :ed25519})
    rsa_user_key = rsa_key()

    {:ok, daemon} =
      :ssh.daemon({127, 0, 0, 1}, 0,
        key_cb:
          {PurpleFlow.Test.SshServer.Keys,
           host_key: host_key,
           user_keys: Enum.map([user_key, rsa_user_key], &:ssh_file.extract_public_key/1)},
        user_passwords: [{~c"deploy", ~c"hunter2"}],
        ssh_cli: {PurpleFlow.Test.SshServer.Channel, [handler, self()]},
        subsystems: []
      )

    ExUnit.Callbacks.on_exit(fn -> :ssh.stop_daemon(daemon) end)
    {:ok, info} = :ssh.daemon_info(daemon)

    %{
      port: info[:port],
      host_key_fingerprint:
        PurpleFlow.Nodes.Ssh.Keys.fingerprint(:ssh_file.extract_public_key(host_key)),
      user_key: openssh_ed25519(user_key),
      rsa_user_key:
        :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, rsa_user_key)])
    }
  end

  # RSA keys are slow to make, so every server shares one.
  defp rsa_key do
    case :persistent_term.get({__MODULE__, :rsa}, nil) do
      nil ->
        key = :public_key.generate_key({:rsa, 2048, 65537})
        :persistent_term.put({__MODULE__, :rsa}, key)
        key

      key ->
        key
    end
  end

  # The "openssh-key-v1" format, unencrypted. (OTP's :ssh_file.encode
  # writes ed25519 keys that its own decoder can't read.)
  defp openssh_ed25519({:ECPrivateKey, _, private, _, public, _}) do
    string = fn bin -> <<byte_size(bin)::32, bin::binary>> end
    public_blob = string.("ssh-ed25519") <> string.(public)
    check = :crypto.strong_rand_bytes(4)

    keys =
      check <> check <> public_blob <> string.(private <> public) <> string.("test@purpleflow")

    padding =
      for i <- 1..(8 - rem(byte_size(keys), 8))//1,
          rem(byte_size(keys), 8) != 0,
          into: "",
          do: <<i>>

    blob =
      "openssh-key-v1\0" <>
        string.("none") <>
        string.("none") <>
        string.("") <> <<1::32>> <> string.(public_blob) <> string.(keys <> padding)

    body = Base.encode64(blob)
    lines = for <<line::binary-size(70) <- body>>, do: line
    rest = binary_part(body, 70 * length(lines), byte_size(body) - 70 * length(lines))

    Enum.join(
      ["-----BEGIN OPENSSH PRIVATE KEY-----"] ++
        lines ++ [rest, "-----END OPENSSH PRIVATE KEY-----"],
      "\n"
    ) <> "\n"
  end
end
