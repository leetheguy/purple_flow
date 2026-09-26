defmodule PurpleFlow.Credentials do
  @moduledoc """
  Named secrets, encrypted at rest, referenced from a workflow as
  `{{ creds.NAME }}`.

  A workflow only ever reads a credential, by name, through `get/1`. There
  is no way for a workflow, a node, or anything building either to create,
  set, or see one — that only happens through this module's other
  functions, used by the `/credentials` UI.
  """

  import Ecto.Query

  alias PurpleFlow.Credentials.{Cipher, Credential}
  alias PurpleFlow.Repo

  @doc """
  Every active credential's `id`, `name`, `description`, and whether it's
  set (`key` present) — never the key itself. Newest first.
  """
  def list do
    from(c in Credential,
      where: is_nil(c.archived_at),
      order_by: [desc: c.inserted_at],
      select: %{id: c.id, name: c.name, description: c.description, set: not is_nil(c.key)}
    )
    |> Repo.all()
  end

  @doc """
  The decrypted value of the active credential named `name`, or `nil` if
  it's unset, archived, or was never created. The only function that ever
  produces a plaintext value.
  """
  @spec get(String.t()) :: String.t() | nil
  def get(name) do
    case Repo.one(from c in Credential, where: c.name == ^name and is_nil(c.archived_at)) do
      %Credential{key: nil} -> nil
      %Credential{key: key} -> Cipher.decrypt(key)
      nil -> nil
    end
  end

  @doc """
  Whether an active credential named `name` exists and has a value set.
  Never decrypts anything; used to check a workflow when it loads.
  """
  @spec set?(String.t()) :: boolean()
  def set?(name) do
    Repo.exists?(
      from c in Credential,
        where: c.name == ^name and is_nil(c.archived_at) and not is_nil(c.key)
    )
  end

  @doc """
  The PubSub topic that hears `:credentials_changed` after every create,
  update, and archive. `PurpleFlow.Workflows` reloads on it, so a workflow
  that failed only because a credential wasn't set starts working.
  """
  def topic, do: "credentials"

  @doc "Creates a new, active, unset credential."
  def create(name, description) do
    %Credential{}
    |> changeset(%{name: name, description: description})
    |> Repo.insert()
    |> announce()
  end

  @doc """
  Updates `name`, `description`, and/or `key` on an existing credential.
  `attrs` may include any of the three; a plaintext `key` is encrypted
  before it's written.
  """
  def update(id, attrs) do
    Repo.get!(Credential, id)
    |> changeset(attrs)
    |> Repo.update()
    |> announce()
  end

  @doc """
  Archives a credential: stamps `archived_at` and replaces `name` with a
  random value, in one update, so the original name is immediately free for
  reuse and a reader never observes a half-archived row.
  """
  def archive(id) do
    Repo.get!(Credential, id)
    |> Ecto.Changeset.change(name: random_name(), archived_at: DateTime.utc_now())
    |> Repo.update()
    |> announce()
  end

  defp announce({:ok, _} = result) do
    Phoenix.PubSub.broadcast(PurpleFlow.PubSub, topic(), :credentials_changed)
    result
  end

  defp announce(result), do: result

  defp changeset(credential, attrs) do
    attrs = normalize_key(attrs)

    credential
    |> Ecto.Changeset.cast(attrs, [:name, :description, :key])
    |> Ecto.Changeset.validate_required([:name])
    |> validate_name()
    |> Ecto.Changeset.unique_constraint(:name)
  end

  # A plaintext `key` in attrs (atom or string key, since this takes both
  # internal calls and raw LiveView form params) gets encrypted before it's
  # cast into the changeset. Callers never pass an already-encrypted value.
  # An empty or missing key means "leave the stored value alone." The
  # encrypted value goes back under the same kind of key it came in under,
  # since Ecto rejects a map mixing atom and string keys.
  defp normalize_key(attrs) do
    field = if Map.has_key?(attrs, "key"), do: "key", else: :key

    case Map.get(attrs, field) do
      value when is_binary(value) and value != "" -> Map.put(attrs, field, Cipher.encrypt(value))
      _ -> Map.delete(attrs, field)
    end
  end

  defp validate_name(changeset) do
    Ecto.Changeset.validate_change(changeset, :name, fn :name, name ->
      cond do
        String.trim(name) != name ->
          [name: "can't have leading or trailing whitespace"]

        String.contains?(name, ".") ->
          [name: "can't contain \".\""]

        String.contains?(name, "{") or String.contains?(name, "}") ->
          [name: "can't contain \"{\" or \"}\""]

        true ->
          []
      end
    end)
  end

  defp random_name, do: "archived-" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
end
