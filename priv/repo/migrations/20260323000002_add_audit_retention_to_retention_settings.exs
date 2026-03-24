defmodule Joy.Repo.Migrations.AddAuditRetentionToRetentionSettings do
  use Ecto.Migration

  def change do
    alter table(:retention_settings) do
      add :audit_retention_days, :integer, default: 365
    end
  end
end
