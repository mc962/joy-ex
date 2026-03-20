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

    has_many :transform_steps, Joy.Channels.TransformStep, preload_order: [asc: :position]
    has_many :destination_configs, Joy.Channels.DestinationConfig

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for creating or updating a channel."
  def changeset(channel, attrs) do
    channel
    |> cast(attrs, [:name, :description, :mllp_port, :started])
    |> validate_required([:name, :mllp_port])
    |> validate_length(:name, min: 2, max: 100)
    |> validate_number(:mllp_port, greater_than_or_equal_to: 1024, less_than_or_equal_to: 65535)
    |> unique_constraint(:mllp_port, message: "is already in use by another channel")
  end
end
