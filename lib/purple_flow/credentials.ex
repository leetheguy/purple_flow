defmodule PurpleFlow.Credentials do
  @moduledoc """
  Named secrets, encrypted at rest, referenced from a workflow as
  `{{ creds.NAME }}`.

  A credential is a plain value (a one-line string, or text that can span
  lines), or an OAuth login whose `get/1` is a working access token (see
  `PurpleFlow.Credentials.OAuth`).

  A workflow only ever reads a credential, by name, through `get/1`. There
  is no way for a workflow, a node, or anything building either to create,
  set, or see one — that only happens through this module's other
  functions, used by the `/credentials` UI.
  """

  import Ecto.Query

  alias PurpleFlow.Credentials.{Cipher, Credential, OAuth}
  alias PurpleFlow.Repo

  @doc """
  Every active credential's `id`, `name`, `description`, `type`, and
  whether it's set (`key` present) — never the key itself. OAuth ones also
  have their settings (`oauth`) and `oauth_error`. Newest first.
  """
  def list do
    from(c in Credential,
      where: is_nil(c.archived_at),
      order_by: [desc: c.inserted_at],
      select: %{
        id: c.id,
        name: c.name,
        description: c.description,
        type: c.type,
        oauth: c.oauth,
        oauth_error: c.oauth_error,
        set: not is_nil(c.key)
      }
    )
    |> Repo.all()
  end

  @doc """
  The value of the active credential named `name`, or `nil` if it's unset,
  archived, or was never created. The only function that ever produces a
  plaintext value.

  What the value is depends on the type: a string or text credential's
  decrypted value, or an OAuth credential's working access token (renewed first if
  it's expired), or `{:error, message}` if it can't be renewed.
  """
  @spec get(String.t()) :: String.t() | nil | {:error, String.t()}
  def get(name) do
    case Repo.one(from c in Credential, where: c.name == ^name and is_nil(c.archived_at)) do
      %Credential{key: nil} -> nil
      %Credential{type: "oauth"} = cred -> OAuth.access_token(cred)
      %Credential{key: key} -> Cipher.decrypt(key)
      nil -> nil
    end
  end

  @doc "The active credential with this `id`, or `nil`. For connecting an OAuth one."
  def fetch(id) do
    Repo.one(from c in Credential, where: c.id == ^id and is_nil(c.archived_at))
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

  @doc """
  Creates a new, active, unset credential. `attrs` may add `type`,
  `oauth` (its settings), and `client_secret`.
  """
  def create(name, description, attrs \\ %{}) do
    %Credential{}
    |> changeset(Map.merge(attrs, %{name: name, description: description}))
    |> Repo.insert()
    |> announce()
  end

  @doc """
  Creates an unset string credential for each `{name, description}`, and
  announces the change once, not once each, so workflows reload once.
  Returns `{created_names, [{name, changeset}]}` for the ones that failed.
  """
  def create_stubs(stubs) do
    results =
      for {name, description} <- stubs do
        {name,
         %Credential{} |> changeset(%{name: name, description: description}) |> Repo.insert()}
      end

    created = for {name, {:ok, _}} <- results, do: name
    failed = for {name, {:error, changeset}} <- results, do: {name, changeset}
    if created != [], do: announce({:ok, created})
    {created, failed}
  end

  @doc """
  Updates `name`,`description`, `key`, and, for OAuth, `oauth` and
  `client_secret` on an existing credential. A plaintext `key` or
  `client_secret` is encrypted before it's written; a blank one leaves the
  stored value alone.
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
    attrs = attrs |> encrypt(:key) |> encrypt(:client_secret)

    credential
    |> Ecto.Changeset.cast(attrs, [:name, :description, :key, :type, :oauth, :client_secret])
    |> Ecto.Changeset.validate_required([:name])
    |> Ecto.Changeset.validate_inclusion(:type, ["string", "text", "oauth"])
    |> validate_oauth()
    |> validate_name()
    |> Ecto.Changeset.unique_constraint(:name)
  end

  # A plaintext secret in attrs (atom or string key, since this takes both
  # internal calls and raw LiveView form params) gets encrypted before it's
  # cast into the changeset. Callers never pass an already-encrypted value.
  # An empty or missing one means "leave the stored value alone." The
  # encrypted value goes back under the same kind of key it came in under,
  # since Ecto rejects a map mixing atom and string keys.
  defp encrypt(attrs, name) do
    field = if Map.has_key?(attrs, to_string(name)), do: to_string(name), else: name

    case Map.get(attrs, field) do
      value when is_binary(value) and value != "" -> Map.put(attrs, field, Cipher.encrypt(value))
      _ -> Map.delete(attrs, field)
    end
  end

  # An OAuth credential needs at least a client ID to connect with.
  defp validate_oauth(changeset) do
    oauth = Ecto.Changeset.get_field(changeset, :oauth) || %{}

    if Ecto.Changeset.get_field(changeset, :type) == "oauth" and
         String.trim(oauth["client_id"] || "") == "",
       do: Ecto.Changeset.add_error(changeset, :oauth, "needs a client ID"),
       else: changeset
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
