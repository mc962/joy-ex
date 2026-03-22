defmodule Joy.ChannelStats do
  @moduledoc """
  ETS-backed per-channel counters for today's message throughput.

  Tracks received/processed/failed counts since midnight UTC. Counters reset
  automatically when the date changes (detected lazily on read). Lost on node
  restart — this is acceptable for "today" metrics.

  Called from:
    - Joy.MLLP.Connection on message receive (incr_received)
    - Joy.Channel.Pipeline on success/failure (incr_processed, incr_failed)

  # GO-TRANSLATION:
  # sync/atomic counters in a struct guarded by a date-check mutex.
  # ETS :update_counter is lock-free and O(1) — no mutex needed.
  """

  use GenServer
  require Logger

  @table :channel_stats

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc "Increment messages received today for a channel."
  def incr_received(channel_id) do
    ensure_row(channel_id)
    :ets.update_counter(@table, channel_id, {3, 1})
    :ok
  end

  @doc "Increment messages processed today for a channel."
  def incr_processed(channel_id) do
    ensure_row(channel_id)
    :ets.update_counter(@table, channel_id, {4, 1})
    :ok
  end

  @doc "Increment messages failed today for a channel."
  def incr_failed(channel_id) do
    ensure_row(channel_id)
    :ets.update_counter(@table, channel_id, {5, 1})
    :ok
  end

  @doc """
  Get today's stats for a channel.
  Returns %{received: n, processed: n, failed: n, retry_queue_depth: n}.
  Resets counters if the stored date is before today.
  """
  def get_today(channel_id) do
    today = Date.utc_today()

    row =
      case :ets.lookup(@table, channel_id) do
        [{^channel_id, stored_date, recv, proc, fail}] ->
          if stored_date == today do
            {recv, proc, fail}
          else
            # Day rolled over — reset counters
            :ets.insert(@table, {channel_id, today, 0, 0, 0})
            {0, 0, 0}
          end

        [] ->
          :ets.insert(@table, {channel_id, today, 0, 0, 0})
          {0, 0, 0}
      end

    {recv, proc, fail} = row
    depth = retry_queue_depth(channel_id)
    %{received: recv, processed: proc, failed: fail, retry_queue_depth: depth}
  end

  # Pending entry count = approximate retry queue depth.
  defp retry_queue_depth(channel_id) do
    import Ecto.Query
    Joy.Repo.one(
      from e in Joy.MessageLog.Entry,
      where: e.channel_id == ^channel_id and e.status == "pending",
      select: count(e.id)
    ) || 0
  rescue
    _ -> 0
  end

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true, write_concurrency: true])
    {:ok, %{}}
  end

  # Initialize a row for this channel if it doesn't exist yet.
  defp ensure_row(channel_id) do
    today = Date.utc_today()
    case :ets.lookup(@table, channel_id) do
      [] -> :ets.insert_new(@table, {channel_id, today, 0, 0, 0})
      [{^channel_id, stored_date, _, _, _}] when stored_date != today ->
        :ets.insert(@table, {channel_id, today, 0, 0, 0})
      _ -> :ok
    end
  end
end
