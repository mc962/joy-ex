defmodule Joy.Channels.Channel do
  @moduledoc """
  Ecto schema for a configured channel.

  `started` is the user's DESIRED runtime state (true = should be running).
  `paused` means the pipeline stops dispatching but the MLLP server keeps accepting.
  Check `Joy.ChannelManager.channel_running?/1` for actual live status.

  TLS config stores PEM content directly in the database:
    - tls_cert_pem: server certificate (public, plain text)
    - tls_key_pem: private key (encrypted at rest via Joy.Encrypted.StringType)
    - tls_ca_cert_pem: CA certificate for verifying client certs in mTLS (public, plain text)
    - tls_cert_expires_at: parsed from cert at save time; used by Joy.CertMonitor

  # GO-TRANSLATION:
  # struct with json tags. Ecto changesets replace manual validation functions.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "channels" do
    field :name, :string
    field :description, :string
    field :mllp_port, :integer
    field :started, :boolean, default: false
    field :allowed_ips, {:array, :string}, default: []

    # Pause/Resume (item 4)
    field :paused, :boolean, default: false

    # MLLP TLS (item 1) — PEM content stored in DB, not file paths
    field :tls_enabled, :boolean, default: false
    field :tls_cert_pem, :string
    field :tls_key_pem, Joy.Encrypted.StringType
    field :tls_ca_cert_pem, :string
    field :tls_cert_expires_at, :utc_datetime
    field :tls_verify_peer, :boolean, default: false

    # Alerting (item 8)
    field :alert_enabled, :boolean, default: false
    field :alert_threshold, :integer, default: 5
    field :alert_email, :string
    field :alert_webhook_url, :string
    field :alert_cooldown_minutes, :integer, default: 60

    belongs_to :organization, Joy.Organizations.Organization

    has_many :transform_steps, Joy.Channels.TransformStep, preload_order: [asc: :position]
    has_many :destination_configs, Joy.Channels.DestinationConfig

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for creating or updating a channel."
  def changeset(channel, attrs) do
    channel
    |> cast(attrs, [
      :name, :description, :mllp_port, :started, :allowed_ips, :paused,
      :tls_enabled, :tls_cert_pem, :tls_key_pem, :tls_ca_cert_pem,
      :tls_cert_expires_at, :tls_verify_peer,
      :alert_enabled, :alert_threshold, :alert_email, :alert_webhook_url,
      :alert_cooldown_minutes, :organization_id
    ])
    |> validate_required([:name, :mllp_port])
    |> validate_length(:name, min: 2, max: 100)
    |> validate_number(:mllp_port, greater_than_or_equal_to: 1024, less_than_or_equal_to: 65535)
    |> unique_constraint(:mllp_port, message: "is already in use by another channel")
    |> Joy.IPValidator.validate_allowed_ips()
    |> validate_tls()
    |> validate_number(:alert_threshold, greater_than: 0)
    |> validate_number(:alert_cooldown_minutes, greater_than: 0)
  end

  defp validate_tls(changeset) do
    if get_field(changeset, :tls_enabled) do
      changeset
      |> validate_required([:tls_cert_pem],
        message: "is required when TLS is enabled")
      |> validate_key_present()
    else
      changeset
    end
  end

  # Key is required when TLS is enabled. We use get_field (not get_change) so that
  # existing records with a stored key pass validation even when the key isn't re-submitted.
  defp validate_key_present(changeset) do
    case get_field(changeset, :tls_key_pem) do
      nil -> add_error(changeset, :tls_key_pem, "is required when TLS is enabled")
      "" -> add_error(changeset, :tls_key_pem, "is required when TLS is enabled")
      _ -> changeset
    end
  end

end
