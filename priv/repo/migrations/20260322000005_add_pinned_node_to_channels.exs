defmodule Joy.Repo.Migrations.AddPinnedNodeToChannels do
  use Ecto.Migration

  def change do
    alter table(:channels) do
      add :pinned_node, :string, null: true
    end
  end
end
