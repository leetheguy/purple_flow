defmodule PurpleFlow.Repo.Migrations.AddOauthToCredentials do
  use Ecto.Migration

  # OAuth credentials: specs/200_oauth_credentials.md.
  def change do
    alter table(:credentials) do
      add :type, :text, null: false, default: "text"
      # client_id, scopes, auth_url, token_url: settings, not secrets.
      add :oauth, :map
      add :client_secret, :binary
      add :oauth_error, :text
    end
  end
end
