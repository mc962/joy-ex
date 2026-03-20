defmodule Joy.Channels.DestinationConfig do
  @moduledoc """
  Ecto schema for a destination adapter configuration.
  The `config` map is AES-256-GCM encrypted at rest via Joy.Encrypted.MapType.

  # GO-TRANSLATION:
  # Go would use interface{} or a discriminated union for adapter config.
  # Elixir uses a generic encrypted map; adapter-specific validation on write.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @valid_adapters ~w[aws_sns aws_sqs http_webhook mllp_forward redis_queue file sink]

  @type t :: %__MODULE__{}

  schema "destination_configs" do
    field :name, :string
    field :adapter, :string
    field :config, Joy.Encrypted.MapType
    field :retry_attempts, :integer, default: 3
    field :retry_base_ms, :integer, default: 1000
    field :enabled, :boolean, default: true

    belongs_to :channel, Joy.Channels.Channel

    timestamps(type: :utc_datetime)
  end

  def changeset(dest, attrs) do
    dest
    |> cast(attrs, [:name, :adapter, :config, :retry_attempts, :retry_base_ms, :enabled, :channel_id])
    |> validate_required([:name, :adapter, :channel_id])
    |> validate_inclusion(:adapter, @valid_adapters)
    |> validate_number(:retry_attempts, greater_than_or_equal_to: 1, less_than_or_equal_to: 10)
    |> validate_number(:retry_base_ms, greater_than_or_equal_to: 100)
  end
end
