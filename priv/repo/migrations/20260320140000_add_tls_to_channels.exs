defmodule Joy.Repo.Migrations.AddTlsToChannels do
  use Ecto.Migration

  def change do
    alter table(:channels) do
      add :tls_enabled, :boolean, null: false, default: false
      add :tls_cert_path, :string
      add :tls_key_path, :string
      add :tls_ca_cert_path, :string
      add :tls_verify_peer, :boolean, null: false, default: false
    end
  end
end
