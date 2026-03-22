defmodule Joy.Repo.Migrations.CreateOrganizations do
  use Ecto.Migration

  def change do
    create table(:organizations) do
      add :name, :string, null: false
      add :slug, :string, null: false
      add :description, :text
      add :allowed_ips, {:array, :string}, default: []
      add :alert_email, :string
      add :alert_webhook_url, :string
      add :tls_ca_cert_pem, :text

      timestamps(type: :utc_datetime)
    end

    create unique_index(:organizations, [:slug])
  end
end
