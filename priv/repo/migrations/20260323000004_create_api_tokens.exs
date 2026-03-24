defmodule Joy.Repo.Migrations.CreateApiTokens do
  use Ecto.Migration

  def change do
    create table(:api_tokens) do
      add :user_id,      references(:users, on_delete: :delete_all), null: false
      add :name,         :string, null: false
      add :token_hash,   :string, null: false
      add :last_used_at, :utc_datetime
      add :inserted_at,  :utc_datetime, null: false
    end

    create unique_index(:api_tokens, [:token_hash])
    create index(:api_tokens, [:user_id])
  end
end
