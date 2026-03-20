defmodule Joy.Repo.Migrations.CreateMessageLogEntries do
  use Ecto.Migration

  def change do
    create table(:message_log_entries) do
      add :channel_id, references(:channels, on_delete: :delete_all), null: false
      add :message_control_id, :string
      add :status, :string, null: false, default: "pending"
      add :raw_hl7, :text
      add :transformed_hl7, :text
      add :error, :text
      add :processed_at, :utc_datetime
      add :inserted_at, :utc_datetime, null: false
    end

    create index(:message_log_entries, [:channel_id, :status])
    create unique_index(:message_log_entries, [:channel_id, :message_control_id],
             where: "message_control_id IS NOT NULL")
    create index(:message_log_entries, [:inserted_at])
  end
end
