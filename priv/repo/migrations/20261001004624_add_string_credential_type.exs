defmodule PurpleFlow.Repo.Migrations.AddStringCredentialType do
  use Ecto.Migration

  # "text" now means a multi-line value; every credential so far was a
  # one-line value, which is "string". specs/230_credential_value_types.md.
  def up do
    execute "UPDATE credentials SET type = 'string' WHERE type = 'text'"

    alter table(:credentials) do
      modify :type, :text, null: false, default: "string"
    end
  end

  def down do
    execute "UPDATE credentials SET type = 'text' WHERE type = 'string'"

    alter table(:credentials) do
      modify :type, :text, null: false, default: "text"
    end
  end
end
