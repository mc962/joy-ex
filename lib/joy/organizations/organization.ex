defmodule Joy.Organizations.Organization do
  @moduledoc """
  Ecto schema for an organization (health system grouping channels).

  Organizations group channels under a shared name with shared config that
  flows down as fallbacks: allowed_ips, alert_email, alert_webhook_url, tls_ca_cert_pem.

  Slug is auto-generated from name when not provided.

  # GO-TRANSLATION:
  # struct with json tags. Ecto changesets replace manual validation functions.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "organizations" do
    field :name, :string
    field :slug, :string
    field :description, :string
    field :allowed_ips, {:array, :string}, default: []
    field :alert_email, :string
    field :alert_webhook_url, :string
    field :tls_ca_cert_pem, :string

    has_many :channels, Joy.Channels.Channel
    has_many :users, Joy.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for creating or updating an organization."
  def changeset(org, attrs) do
    org
    |> cast(attrs, [:name, :slug, :description, :allowed_ips, :alert_email, :alert_webhook_url, :tls_ca_cert_pem])
    |> validate_required([:name])
    |> validate_length(:name, min: 2, max: 200)
    |> maybe_generate_slug()
    |> validate_required([:slug])
    |> validate_format(:slug, ~r/^[a-z0-9-]+$/, message: "must contain only lowercase letters, numbers, and hyphens")
    |> unique_constraint(:slug, message: "is already taken")
    |> Joy.IPValidator.validate_allowed_ips()
  end

  defp maybe_generate_slug(changeset) do
    case get_change(changeset, :name) do
      nil -> changeset
      name -> put_change(changeset, :slug, slugify(name))
    end
  end

  defp slugify(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end
end
