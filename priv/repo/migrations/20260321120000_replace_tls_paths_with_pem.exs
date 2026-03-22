defmodule Joy.Repo.Migrations.ReplaceTlsPathsWithPem do
  use Ecto.Migration

  def change do
    alter table(:channels) do
      remove :tls_cert_path, :string
      remove :tls_key_path, :string
      remove :tls_ca_cert_path, :string

      add :tls_cert_pem, :text
      add :tls_key_pem, :binary
      add :tls_ca_cert_pem, :text
      add :tls_cert_expires_at, :utc_datetime
    end
  end
end
