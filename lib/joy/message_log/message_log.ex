defmodule Joy.MessageLog do
  @moduledoc """
  Context for the message audit log.

  persist_pending/3 must be called BEFORE sending the MLLP ACK.
  This guarantees at-least-once delivery: if the server crashes after persisting
  but before processing, the pipeline requeues on restart. If we crash before
  persisting, the sender retries (no ACK received).

  # GO-TRANSLATION:
  # database/sql with explicit ON CONFLICT clause.
  # The Ecto.Changeset approach wraps this in a struct-oriented API.
  """

  import Ecto.Query
  alias Joy.{Repo, MessageLog.Entry}

  @doc """
  Write a message to the log as :pending. Uses upsert-on-conflict for idempotency
  (duplicate message_control_ids from the same channel are ignored).
  """
  @spec persist_pending(integer(), String.t() | nil, String.t()) ::
          {:ok, Entry.t()} | {:error, any()}
  def persist_pending(channel_id, message_control_id, raw_hl7) do
    attrs = %{
      channel_id: channel_id,
      message_control_id: message_control_id,
      raw_hl7: raw_hl7
    }

    %Entry{}
    |> Entry.insert_changeset(attrs)
    |> Repo.insert(
      on_conflict: :nothing,
      conflict_target: {:unsafe_fragment, "(channel_id, message_control_id) WHERE message_control_id IS NOT NULL"},
      returning: true
    )
  end

  @doc "Mark an entry as successfully processed."
  def mark_processed(entry_id, transformed_hl7) do
    entry = Repo.get!(Entry, entry_id)

    entry
    |> Entry.update_status_changeset(%{
      status: "processed",
      transformed_hl7: transformed_hl7,
      error: nil,
      processed_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.update()
    |> tap_ok(fn e ->
      Phoenix.PubSub.broadcast(Joy.PubSub, "message_log:#{e.channel_id}", {:new_entry, e})
    end)
  end

  @doc "Mark an entry as failed with an error message."
  def mark_failed(entry_id, error_message) do
    entry = Repo.get!(Entry, entry_id)

    entry
    |> Entry.update_status_changeset(%{
      status: "failed",
      error: error_message,
      processed_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.update()
    |> tap_ok(fn e ->
      Phoenix.PubSub.broadcast(Joy.PubSub, "message_log:#{e.channel_id}", {:new_entry, e})
    end)
  end

  @doc """
  Mark an existing entry as retried and insert a fresh pending entry for the same
  raw message. Returns {:ok, new_entry} so the caller can queue the new entry_id
  for processing.
  """
  def retry_entry(%Entry{} = original) do
    Repo.transaction(fn ->
      {:ok, _} =
        original
        |> Entry.update_status_changeset(%{status: "retried", error: nil})
        |> Repo.update()

      Phoenix.PubSub.broadcast(
        Joy.PubSub,
        "message_log:#{original.channel_id}",
        {:new_entry, %{original | status: "retried"}}
      )

      {:ok, new_entry} =
        %Entry{}
        |> Entry.insert_changeset(%{
          channel_id: original.channel_id,
          message_control_id: nil,
          raw_hl7: original.raw_hl7
        })
        |> Repo.insert()

      Phoenix.PubSub.broadcast(
        Joy.PubSub,
        "message_log:#{new_entry.channel_id}",
        {:new_entry, new_entry}
      )

      new_entry
    end)
  end

  @doc "List all :pending entries for a channel (for requeue on pipeline restart)."
  def list_pending(channel_id) do
    Entry
    |> where([e], e.channel_id == ^channel_id and e.status == "pending")
    |> order_by([e], asc: e.inserted_at)
    |> Repo.all()
  end

  @doc "List recent entries. Opts: limit (default 50), status (nil = all)."
  def list_recent(channel_id \\ nil, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    status = Keyword.get(opts, :status)

    Entry
    |> then(fn q -> if channel_id, do: where(q, [e], e.channel_id == ^channel_id), else: q end)
    |> then(fn q -> if status, do: where(q, [e], e.status == ^status), else: q end)
    |> order_by([e], desc: e.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc "Get a single entry by id. Raises if not found."
  def get_entry!(id), do: Repo.get!(Entry, id)

  defp tap_ok({:ok, val} = result, fun), do: (fun.(val); result)
  defp tap_ok(result, _fun), do: result
end
