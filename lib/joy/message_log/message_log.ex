defmodule Joy.MessageLog do
  @moduledoc """
  Context for the message audit log.

  persist_pending/3 must be called BEFORE sending the MLLP ACK.
  This guarantees at-least-once delivery: if the server crashes after persisting
  but before processing, the pipeline requeues on restart. If we crash before
  persisting, the sender retries (no ACK received).

  message_type (MSH.9) and patient_id (PID.3) are extracted at persist time
  so the message log can be filtered without scanning raw_hl7 (item 6).

  # GO-TRANSLATION:
  # database/sql with explicit ON CONFLICT clause.
  # The Ecto.Changeset approach wraps this in a struct-oriented API.
  """

  import Ecto.Query
  alias Joy.{Repo, MessageLog.Entry}

  @doc """
  Write a message to the log as :pending. Uses upsert-on-conflict for idempotency
  (duplicate message_control_ids from the same channel are ignored).

  Extracts message_type from MSH.9 and patient_id from PID.3 for search.
  """
  @spec persist_pending(integer(), String.t() | nil, String.t()) ::
          {:ok, Entry.t()} | {:error, any()}
  def persist_pending(channel_id, message_control_id, raw_hl7) do
    {message_type, patient_id} = extract_search_fields(raw_hl7)

    attrs = %{
      channel_id: channel_id,
      message_control_id: message_control_id,
      raw_hl7: raw_hl7,
      message_type: message_type,
      patient_id: patient_id
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
          raw_hl7: original.raw_hl7,
          message_type: original.message_type,
          patient_id: original.patient_id
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

  @doc """
  Retry all :failed entries for a channel. Each entry is marked :retried and a new
  :pending entry is created and dispatched. Returns {:ok, count}.
  """
  def retry_all_failed(channel_id) do
    failed =
      Entry
      |> where([e], e.channel_id == ^channel_id and e.status == "failed")
      |> Repo.all()

    count =
      Enum.count(failed, fn entry ->
        case retry_entry(entry) do
          {:ok, new_entry} ->
            Joy.Channel.Pipeline.process_async(channel_id, new_entry.id)
            true
          {:error, _} ->
            false
        end
      end)

    {:ok, count}
  end

  @doc "List all :pending entries for a channel (for requeue on pipeline restart)."
  def list_pending(channel_id) do
    Entry
    |> where([e], e.channel_id == ^channel_id and e.status == "pending")
    |> order_by([e], asc: e.inserted_at)
    |> Repo.all()
  end

  @doc """
  List recent entries with optional filtering.

  Opts:
    - limit: integer (default 50)
    - status: string | nil
    - message_type: string | nil — substring match on MSH.9
    - patient_id: string | nil — substring match on PID.3
    - date_from: Date | nil
    - date_to: Date | nil
  """
  def list_recent(channel_id \\ nil, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    status = Keyword.get(opts, :status)
    message_type = Keyword.get(opts, :message_type)
    patient_id = Keyword.get(opts, :patient_id)
    date_from = Keyword.get(opts, :date_from)
    date_to = Keyword.get(opts, :date_to)

    Entry
    |> then(fn q -> if channel_id, do: where(q, [e], e.channel_id == ^channel_id), else: q end)
    |> then(fn q -> if status, do: where(q, [e], e.status == ^status), else: q end)
    |> then(fn q ->
      if message_type && message_type != "" do
        mt = "%#{message_type}%"
        where(q, [e], ilike(e.message_type, ^mt))
      else
        q
      end
    end)
    |> then(fn q ->
      if patient_id && patient_id != "" do
        pid_str = "%#{patient_id}%"
        where(q, [e], ilike(e.patient_id, ^pid_str))
      else
        q
      end
    end)
    |> then(fn q ->
      if date_from do
        dt_from = DateTime.new!(date_from, ~T[00:00:00], "Etc/UTC")
        where(q, [e], e.inserted_at >= ^dt_from)
      else
        q
      end
    end)
    |> then(fn q ->
      if date_to do
        dt_to = DateTime.new!(date_to, ~T[23:59:59], "Etc/UTC")
        where(q, [e], e.inserted_at <= ^dt_to)
      else
        q
      end
    end)
    |> order_by([e], desc: e.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc "List all :failed entries across all channels (global DLQ view)."
  def list_all_failed(opts \\ []) do
    limit = Keyword.get(opts, :limit, 200)

    Entry
    |> where([e], e.status == "failed")
    |> order_by([e], desc: e.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc "Count all :failed entries across all channels."
  def count_all_failed do
    Repo.one(from e in Entry, where: e.status == "failed", select: count(e.id)) || 0
  end

  @doc "Get a single entry by id. Raises if not found."
  def get_entry!(id), do: Repo.get!(Entry, id)

  # Extract MSH.9 (message type/event) and PID.3 (patient ID) from raw HL7.
  # Returns {"ADT^A01", "12345"} or {nil, nil} on any parse issue.
  defp extract_search_fields(raw_hl7) when is_binary(raw_hl7) do
    segments = String.split(raw_hl7, "\r", trim: true)
    message_type = extract_msh9(segments)
    patient_id = extract_pid3(segments)
    {message_type, patient_id}
  end

  defp extract_msh9(segments) do
    case Enum.find(segments, &String.starts_with?(&1, "MSH")) do
      nil -> nil
      msh -> msh |> String.split("|") |> Enum.at(8)
    end
  end

  defp extract_pid3(segments) do
    case Enum.find(segments, &String.starts_with?(&1, "PID")) do
      nil -> nil
      pid ->
        # PID.3 is the 3rd field; take the first component (before ^)
        pid
        |> String.split("|")
        |> Enum.at(3)
        |> case do
          nil -> nil
          field -> field |> String.split("^") |> List.first()
        end
    end
  end

  defp tap_ok({:ok, val} = result, fun), do: (fun.(val); result)
  defp tap_ok(result, _fun), do: result
end
