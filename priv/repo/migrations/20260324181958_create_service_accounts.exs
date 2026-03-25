defmodule Joy.Repo.Migrations.CreateServiceAccounts do
  use Ecto.Migration

  def change do
    create table(:service_accounts) do
      add :name,        :string, null: false
      add :inserted_at, :utc_datetime, null: false
    end

    create table(:service_account_tokens) do
      add :service_account_id, references(:service_accounts, on_delete: :delete_all), null: false
      add :token_hash,         :string, null: false
      add :last_used_at,       :utc_datetime
      add :inserted_at,        :utc_datetime, null: false
    end

    create unique_index(:service_account_tokens, [:token_hash])
    create unique_index(:service_account_tokens, [:service_account_id])
  end
end
