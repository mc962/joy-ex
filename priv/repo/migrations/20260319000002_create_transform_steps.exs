defmodule Joy.Repo.Migrations.CreateTransformSteps do
  use Ecto.Migration

  def change do
    create table(:transform_steps) do
      add :channel_id, references(:channels, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :script, :text, null: false
      add :position, :integer, null: false, default: 0
      add :enabled, :boolean, default: true, null: false
      timestamps(type: :utc_datetime)
    end

    create index(:transform_steps, [:channel_id, :position])
  end
end
