defmodule Joy.Repo.Migrations.CreateChannels do
  use Ecto.Migration

  def change do
    create table(:channels) do
      add :name, :string, null: false
      add :description, :text
      add :mllp_port, :integer, null: false
      add :started, :boolean, default: false, null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:channels, [:mllp_port])
  end
end
