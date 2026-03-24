defmodule Joy.Repo.Migrations.AddExpiresAtToApiTokens do
  use Ecto.Migration

  def change do
    alter table(:api_tokens) do
      add :expires_at, :utc_datetime, null: false,
        default: fragment("now() + interval '90 days'")
    end
  end
end
