defmodule Joy.Repo.Migrations.CreateDestinationConfigs do
  use Ecto.Migration

  def change do
    create table(:destination_configs) do
      add :channel_id, references(:channels, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :adapter, :string, null: false
      add :config, :binary, null: false
      add :retry_attempts, :integer, default: 3, null: false
      add :retry_base_ms, :integer, default: 1000, null: false
      add :enabled, :boolean, default: true, null: false
      timestamps(type: :utc_datetime)
    end

    create index(:destination_configs, [:channel_id])
  end
end
