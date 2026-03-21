defmodule Joy.Repo.Migrations.AddAllowedIpsToChannels do
  use Ecto.Migration

  def change do
    alter table(:channels) do
      add :allowed_ips, {:array, :string}, null: false, default: []
    end
  end
end
