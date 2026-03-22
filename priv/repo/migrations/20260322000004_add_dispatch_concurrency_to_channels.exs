defmodule Joy.Repo.Migrations.AddDispatchConcurrencyToChannels do
  use Ecto.Migration

  def change do
    alter table(:channels) do
      add :dispatch_concurrency, :integer, default: 1, null: false
    end
  end
end
