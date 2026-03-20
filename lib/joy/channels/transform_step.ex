defmodule Joy.Channels.TransformStep do
  @moduledoc """
  Ecto schema for an ordered transform script associated with a channel.
  Scripts are evaluated by Joy.Transform.Runner in a sandboxed task.

  # GO-TRANSLATION:
  # Go would store scripts as plain strings in a struct.
  # Elixir's Code.eval_string has no direct Go equivalent; Go integration
  # engines typically embed Lua or use expr libraries.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "transform_steps" do
    field :name, :string
    field :script, :string
    field :position, :integer, default: 0
    field :enabled, :boolean, default: true

    belongs_to :channel, Joy.Channels.Channel

    timestamps(type: :utc_datetime)
  end

  def changeset(step, attrs) do
    step
    |> cast(attrs, [:name, :script, :position, :enabled, :channel_id])
    |> validate_required([:name, :script, :channel_id])
    |> validate_length(:name, min: 1, max: 100)
  end
end
