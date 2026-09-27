defmodule PurpleFlow.Nodes.Ssh.Keys do
  @moduledoc """
  Keys for `PurpleFlow.Nodes.Ssh`, straight from its config instead of
  `~/.ssh`: the private key to log in with, and the fingerprint the
  server's host key must have. Nothing is read from or written to disk.

  This is an `:ssh_client_key_api` callback module; `:ssh` calls it with
  `key_cb_private: [private_key: ..., host_key: ...]` in its options.
  """

  @behaviour :ssh_client_key_api

  @impl true
  def is_host_key(key, _host, _port, _algorithm, options) do
    case Keyword.get(own(options), :host_key) do
      nil -> true
      expected -> fingerprint(key) == String.trim(expected)
    end
  end

  @impl true
  def add_host_key(_host, _port, _key, _options), do: :ok

  @impl true
  def user_key(algorithm, options) do
    case Keyword.get(own(options), :private_key) do
      nil ->
        {:error, :no_private_key}

      pem ->
        case :ssh_file.decode_ssh_file(:private, algorithm, normalize(pem), :ignore) do
          {:ok, [{key, _attrs} | _]} -> {:ok, key}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc "A public key's fingerprint, as `ssh-keygen -lf` prints it: `\"SHA256:...\"`."
  def fingerprint(key), do: to_string(:ssh.hostkey_fingerprint(:sha256, key))

  @doc """
  Rebuilds a PEM or OpenSSH private key whose line breaks were lost or
  mangled, as happens when one is pasted into a one-line field: the body
  between the `-----BEGIN` and `-----END` lines is re-wrapped.
  """
  def normalize(pem) do
    case Regex.run(~r/(-----BEGIN [A-Z0-9 ]+-----)(.*?)(-----END [A-Z0-9 ]+-----)/s, pem) do
      [_, first, body, last] ->
        body = body |> String.replace("\\n", "") |> String.replace(~r/\s/, "")
        lines = for <<line::binary-size(64) <- body>>, do: line
        tail = binary_part(body, 64 * length(lines), byte_size(body) - 64 * length(lines))
        Enum.join([first | lines] ++ Enum.reject([tail], &(&1 == "")) ++ [last], "\n") <> "\n"

      nil ->
        pem
    end
  end

  defp own(options), do: Keyword.get(options, :key_cb_private, [])
end
