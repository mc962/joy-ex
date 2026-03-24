defmodule Joy.Repo.Migrations.CreateAuditLogEntries do
  use Ecto.Migration

  def change do
    create table(:audit_log_entries) do
      add :actor_id,      references(:users, on_delete: :nilify_all)
      add :actor_email,   :string
      add :action,        :string,      null: false
      add :resource_type, :string,      null: false
      add :resource_id,   :integer
      add :resource_name, :string
      add :changes,       :map
      add :inserted_at,   :utc_datetime, null: false
    end

    create index(:audit_log_entries, [:actor_id])
    create index(:audit_log_entries, [:resource_type])
    create index(:audit_log_entries, [:inserted_at])
  end
end
