defmodule Joy.MessageLog.Entry do
  @moduledoc """
  Ecto schema for the message audit log.

  Written as "pending" BEFORE sending the MLLP ACK to guarantee at-least-once
  delivery. On restart, pending entries are requeued by the pipeline.

  The unique index on (channel_id, message_control_id) provides exactly-once
  semantics via upsert-on-conflict. No updated_at — entries are append-mostly.

  # GO-TRANSLATION:
  # struct with database/sql scanning. Upsert-on-conflict is standard SQL.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w[pending processed failed retried]

  @type t :: %__MODULE__{}

  schema "message_log_entries" do
    field :message_control_id, :string
    field :status, :string, default: "pending"
    field :raw_hl7, :string
    field :transformed_hl7, :string
    field :error, :string
    field :processed_at, :utc_datetime
    field :inserted_at, :utc_datetime

    belongs_to :channel, Joy.Channels.Channel
  end

  @doc "Changeset for inserting new pending entries."
  def insert_changeset(entry, attrs) do
    entry
    |> cast(attrs, [:channel_id, :message_control_id, :raw_hl7, :status])
    |> validate_required([:channel_id, :raw_hl7])
    |> put_change(:inserted_at, DateTime.utc_now() |> DateTime.truncate(:second))
    |> put_change(:status, "pending")
  end

  @doc "Changeset for updating status after processing."
  def update_status_changeset(entry, attrs) do
    entry
    |> cast(attrs, [:status, :transformed_hl7, :error, :processed_at])
    |> validate_inclusion(:status, @statuses)
  end
end
