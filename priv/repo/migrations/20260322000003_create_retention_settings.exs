defmodule Joy.Repo.Migrations.CreateRetentionSettings do
  use Ecto.Migration

  def change do
    create table(:retention_settings) do
      add :retention_days, :integer, null: false, default: 90
      add :schedule_enabled, :boolean, null: false, default: false
      add :schedule_hour, :integer, null: false, default: 2

      # Archive destination: "none" | "local_fs" | "s3" | "glacier"
      add :archive_destination, :string, null: false, default: "none"

      # Local FS config
      add :local_path, :string

      # AWS config (shared by s3 and glacier backends)
      add :aws_bucket, :string
      add :aws_prefix, :string
      add :aws_region, :string
      add :aws_access_key_id, :string     # encrypted at rest
      add :aws_secret_access_key, :string # encrypted at rest

      # Last run tracking
      add :last_purge_at, :utc_datetime
      add :last_purge_deleted, :integer
      add :last_purge_archived, :integer

      timestamps(type: :utc_datetime)
    end
  end
end
