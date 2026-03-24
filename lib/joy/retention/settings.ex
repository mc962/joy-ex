defmodule Joy.Retention.Settings do
  @moduledoc """
  Single-row config table for message log retention.

  archive_destination controls which backend Joy.Retention.Archive dispatches to:
    "none"     — delete only, no archival
    "local_fs" — write gzip NDJSON files to local_path
    "s3"       — upload to S3 with STANDARD storage class
    "glacier"  — upload to S3 with GLACIER storage class

  AWS credentials are stored encrypted via Joy.Encrypted.StringType.
  Leave aws_access_key_id blank to use IAM instance roles (recommended in EC2/ECS).

  # GO-TRANSLATION:
  # single-row config table; same pattern as application_settings in Rails.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @destinations ~w[none local_fs s3 glacier]

  schema "retention_settings" do
    field :retention_days, :integer, default: 90
    field :audit_retention_days, :integer, default: 365
    field :schedule_enabled, :boolean, default: false
    field :schedule_hour, :integer, default: 2

    field :archive_destination, :string, default: "none"

    field :local_path, :string

    field :aws_bucket, :string
    field :aws_prefix, :string
    field :aws_region, :string
    field :aws_access_key_id, Joy.Encrypted.StringType
    field :aws_secret_access_key, Joy.Encrypted.StringType

    field :last_purge_at, :utc_datetime
    field :last_purge_deleted, :integer
    field :last_purge_archived, :integer

    timestamps(type: :utc_datetime)
  end

  def changeset(settings, attrs) do
    settings
    |> cast(attrs, [
      :retention_days, :audit_retention_days, :schedule_enabled, :schedule_hour,
      :archive_destination, :local_path,
      :aws_bucket, :aws_prefix, :aws_region,
      :aws_access_key_id, :aws_secret_access_key
    ])
    |> validate_required([:retention_days, :schedule_enabled, :schedule_hour, :archive_destination])
    |> validate_number(:retention_days, greater_than: 0)
    |> validate_number(:audit_retention_days, greater_than: 0)
    |> validate_number(:schedule_hour, greater_than_or_equal_to: 0, less_than: 24)
    |> validate_inclusion(:archive_destination, @destinations)
    |> validate_archive_config()
  end

  defp validate_archive_config(changeset) do
    case get_field(changeset, :archive_destination) do
      "local_fs" ->
        validate_required(changeset, [:local_path],
          message: "is required when archiving to local filesystem")

      dest when dest in ["s3", "glacier"] ->
        validate_required(changeset, [:aws_bucket, :aws_region],
          message: "is required for AWS archiving")

      _ ->
        changeset
    end
  end
end
