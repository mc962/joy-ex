defmodule Joy.Retention do
  @moduledoc """
  Message log retention: scheduled and on-demand purge with optional archival.

  Purge flow:
    1. Query entries older than retention_days (excluding :pending — they're
       still in-flight and must not be deleted).
    2. If archive_destination != "none", serialize all eligible entries to
       gzip-compressed NDJSON and upload via the configured backend. Entries
       are chunked 50k at a time to bound memory usage; each chunk becomes a
       separate archive file. Abort if any chunk fails — never delete before
       confirming archival.
    3. Delete all eligible entries in batches of 1000 to avoid long-running
       transactions.
    4. Record last_purge_at, last_purge_deleted, last_purge_archived on the
       settings row for UI display.

  The `all: true` option bypasses the retention_days window and purges all
  non-pending entries (useful for full manual cleanup or dev resets).

  # GO-TRANSLATION:
  # Service layer pattern. Retention struct holds config; methods on it run the
  # purge and call the archive interface.
  """

  import Ecto.Query
  require Logger
  alias Joy.{Repo, MessageLog.Entry, Retention.Settings, Retention.Archive}

  @chunk_size 50_000
  @delete_batch_size 1_000

  # --- Settings ---

  @doc "Return the retention settings row, creating defaults on first call."
  def get_settings do
    Repo.one(Settings) || create_default_settings()
  end

  @doc "Update retention settings. Returns {:ok, settings} or {:error, changeset}."
  def update_settings(%Settings{} = settings, attrs) do
    settings
    |> Settings.changeset(attrs)
    |> Repo.update()
  end

  @doc "Return a changeset for UI forms."
  def change_settings(%Settings{} = settings, attrs \\ %{}) do
    Settings.changeset(settings, attrs)
  end

  # --- Stats ---

  @doc "Total entry count in the message log."
  def count_total do
    Repo.aggregate(Entry, :count, :id)
  end

  @doc "Count entries eligible for purge under the current retention window."
  def count_purgeable(%Settings{} = settings) do
    Repo.aggregate(purgeable_query(settings), :count, :id)
  end

  @doc "Timestamp of the oldest entry in the log, or nil."
  def oldest_entry_date do
    Repo.one(from e in Entry, select: min(e.inserted_at))
  end

  # --- Purge ---

  @doc """
  Run a purge cycle. Options:
    - `all: true` — ignore retention_days, purge all non-pending entries.

  Returns `{:ok, %{deleted: n, archived: n}}` or `{:error, reason}`.
  """
  def run_purge(opts \\ []) do
    settings = get_settings()
    query = if Keyword.get(opts, :all, false), do: all_purgeable_query(), else: purgeable_query(settings)
    total = Repo.aggregate(query, :count, :id)

    if total == 0 do
      record_last_purge(settings, 0, 0)
      {:ok, %{deleted: 0, archived: 0}}
    else
      with {:ok, archived} <- maybe_archive(query, settings),
           deleted <- delete_in_batches(query) do
        record_last_purge(settings, deleted, archived)
        Logger.info("[Retention] Purge complete: #{deleted} deleted, #{archived} archived")
        {:ok, %{deleted: deleted, archived: archived}}
      end
    end
  end

  # ---------- private ----------

  defp create_default_settings do
    {:ok, settings} = %Settings{} |> Settings.changeset(%{}) |> Repo.insert()
    settings
  end

  # Entries older than retention_days that are not pending.
  defp purgeable_query(settings) do
    cutoff = DateTime.add(DateTime.utc_now(), -settings.retention_days * 86_400, :second)
    from e in Entry, where: e.inserted_at < ^cutoff and e.status != "pending"
  end

  # All non-pending entries regardless of age.
  defp all_purgeable_query do
    from e in Entry, where: e.status != "pending"
  end

  defp maybe_archive(_query, %Settings{archive_destination: "none"}), do: {:ok, 0}

  defp maybe_archive(query, settings) do
    archiver = Archive.for_destination(settings.archive_destination)
    timestamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%d_%H%M%S")

    ids =
      query
      |> select([e], e.id)
      |> order_by([e], asc: e.id)
      |> Repo.all()

    result =
      ids
      |> Enum.chunk_every(@chunk_size)
      |> Enum.with_index(1)
      |> Enum.reduce_while({:ok, 0}, fn {chunk_ids, idx}, {:ok, acc_count} ->
        filename = "joy_archive_#{timestamp}_part#{idx}.ndjson.gz"

        entries =
          from(e in Entry, where: e.id in ^chunk_ids, order_by: [asc: e.id])
          |> Repo.all()

        ndjson =
          entries
          |> Enum.map_join("\n", &Jason.encode!(entry_to_map(&1)))
          |> then(&(&1 <> "\n"))
          |> :zlib.gzip()

        case archiver.store(ndjson, filename, settings) do
          :ok -> {:cont, {:ok, acc_count + length(entries)}}
          {:error, _} = err -> {:halt, err}
        end
      end)

    result
  end

  defp delete_in_batches(query) do
    ids =
      query
      |> select([e], e.id)
      |> Repo.all()

    ids
    |> Enum.chunk_every(@delete_batch_size)
    |> Enum.reduce(0, fn batch_ids, acc ->
      {count, _} = Repo.delete_all(from e in Entry, where: e.id in ^batch_ids)
      acc + count
    end)
  end

  defp record_last_purge(settings, deleted, archived) do
    settings
    |> Ecto.Changeset.change(
      last_purge_at: DateTime.utc_now() |> DateTime.truncate(:second),
      last_purge_deleted: deleted,
      last_purge_archived: archived
    )
    |> Repo.update()
  end

  defp entry_to_map(entry) do
    %{
      id: entry.id,
      channel_id: entry.channel_id,
      status: entry.status,
      message_control_id: entry.message_control_id,
      message_type: entry.message_type,
      patient_id: entry.patient_id,
      raw_hl7: entry.raw_hl7,
      transformed_hl7: entry.transformed_hl7,
      error: entry.error,
      inserted_at: dt_to_iso(entry.inserted_at),
      processed_at: dt_to_iso(entry.processed_at)
    }
  end

  defp dt_to_iso(nil), do: nil
  defp dt_to_iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
end
