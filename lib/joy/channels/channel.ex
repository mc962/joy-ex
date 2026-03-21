defmodule Joy.Channels.Channel do
  @moduledoc """
  Ecto schema for a configured channel.

  `started` is the user's DESIRED runtime state (true = should be running).
  Check `Joy.ChannelManager.channel_running?/1` for actual live status.
  This separation lets the UI show intent vs. reality cleanly.

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

    has_many :transform_steps, Joy.Channels.TransformStep, preload_order: [asc: :position]
    has_many :destination_configs, Joy.Channels.DestinationConfig

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for creating or updating a channel."
  def changeset(channel, attrs) do
    channel
    |> cast(attrs, [:name, :description, :mllp_port, :started, :allowed_ips])
    |> validate_required([:name, :mllp_port])
    |> validate_length(:name, min: 2, max: 100)
    |> validate_number(:mllp_port, greater_than_or_equal_to: 1024, less_than_or_equal_to: 65535)
    |> unique_constraint(:mllp_port, message: "is already in use by another channel")
    |> validate_change(:allowed_ips, fn :allowed_ips, ips ->
      invalid = Enum.reject(ips, &valid_ip_or_cidr?/1)
      if invalid == [],
        do: [],
        else: [allowed_ips: "contains invalid entries: #{Enum.join(invalid, ", ")}"]
    end)
  end

  # Accepts plain IPs ("10.0.0.5") or CIDR notation ("10.0.0.0/24").
  defp valid_ip_or_cidr?(entry) do
    case String.split(entry, "/", parts: 2) do
      [ip] ->
        match?({:ok, _}, :inet.parse_address(to_charlist(ip)))

      [ip, prefix] ->
        match?({:ok, _}, :inet.parse_address(to_charlist(ip))) and
          match?({n, ""} when n in 0..32, Integer.parse(prefix))
    end
  end
end
