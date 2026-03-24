defmodule Joy.Repo.Migrations.AddAckConfigToChannels do
  use Ecto.Migration

  def change do
    alter table(:channels) do
      add :ack_code_override, :string   # nil | "AA" | "AE" | "AR"
      add :ack_sending_app, :string     # nil = mirror inbound MSH.5
      add :ack_sending_fac, :string     # nil = mirror inbound MSH.6
    end
  end
end
