defmodule Joy.Repo.Migrations.AddOrgFks do
  use Ecto.Migration

  def change do
    alter table(:channels) do
      add :organization_id, references(:organizations, on_delete: :nilify_all)
    end

    create index(:channels, [:organization_id])

    alter table(:users) do
      add :organization_id, references(:organizations, on_delete: :nilify_all)
    end

    create index(:users, [:organization_id])
  end
end
