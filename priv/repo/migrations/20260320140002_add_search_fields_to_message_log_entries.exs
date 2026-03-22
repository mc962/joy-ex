defmodule Joy.Repo.Migrations.AddSearchFieldsToMessageLogEntries do
  use Ecto.Migration

  def change do
    alter table(:message_log_entries) do
      add :message_type, :string
      add :patient_id, :string
    end

    create index(:message_log_entries, [:message_type])
    create index(:message_log_entries, [:patient_id])
  end
end
