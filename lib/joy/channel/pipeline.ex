defmodule Joy.Channel.Pipeline do
  @moduledoc """
  The processing brain of a channel.

  Responsibilities:
    1. Holds channel config (transforms, destinations) in state — no DB hit per message
    2. Requeues :pending log entries on startup (crash recovery)
    3. Processes messages via GenServer.cast (async, non-blocking)
    4. Runs each enabled transform in order via Joy.Transform.Runner
    5. Delivers to all enabled destinations (or only routed ones)
    6. Tracks throughput stats; broadcasts to PubSub for LiveView dashboard
    7. Supports pause/resume: when paused, messages sit as :pending in DB
    8. Reports consecutive failures to Joy.Alerting for alert threshold checking

  ## Dispatch model

  All messages are dispatched via Joy.Channel.WorkerSupervisor (a Task.Supervisor
  owned by Joy.Channel.Supervisor). The GenServer itself never blocks on I/O —
  it only enqueues and dequeues work, updates counters, and broadcasts stats.

  `dispatch_concurrency` (a per-channel DB field, default 1) controls how many
  worker tasks may run at the same time:

    - 1 (default) — strict serial: message B is not started until message A
      completes. Delivery order matches receive order. Same guarantee as the
      previous synchronous implementation, but the GenServer is no longer blocked
      during slow I/O (long HTTP timeouts, etc.).

    - N > 1 — up to N messages processed simultaneously. Higher throughput
      when a channel has many concurrent MLLP senders and a slow destination.
      Trade-off: ordering is NOT guaranteed across concurrent senders — two
      messages that arrive at nearly the same time may complete in either order.
      Within a single MLLP connection, the ACK-before-next protocol already
      serializes sends, so ordering is preserved per-connection regardless.

  Messages that arrive while `in_flight >= concurrency` are held in a local
  FIFO queue in state and started as soon as a slot opens. The GenServer mailbox
  provides outer backpressure.

  ## Crash recovery

  Worker tasks are started with Task.Supervisor.start_child (fire-and-forget,
  no link to Pipeline). If Pipeline crashes mid-task, the task finishes and
  sends {:dispatch_done, ...} to the old (dead) pid — message silently dropped.
  The new Pipeline instance requeues all :pending entries from the DB on startup,
  which will include any entry whose task was in-flight at crash time. This is
  the same at-least-once behaviour as the previous synchronous implementation.

  # GO-TRANSLATION:
  # struct with sync.Mutex protecting config + stats; goroutine reading from chan Message.
  # The GenServer mailbox IS the channel; no explicit chan or mutex needed.
  # State mutation via message passing replaces mutex-protected struct updates.
  """

  use GenServer
  require Logger

  defstruct channel: nil,
            processed_count: 0,
            failed_count: 0,
            last_error: nil,
            last_message_at: nil,
            paused: false,
            in_flight: 0,
            pending_queue: :queue.new()

  def start_link(%Joy.Channels.Channel{} = channel) do
    GenServer.start_link(__MODULE__, channel, name: via(channel.id))
  end

  def child_spec(%Joy.Channels.Channel{id: id} = channel) do
    %{id: {__MODULE__, id}, start: {__MODULE__, :start_link, [channel]}}
  end

  @doc "Dispatch a persisted log entry to this channel's pipeline for async processing."
  def process_async(channel_id, entry_id) do
    case Horde.Registry.lookup(Joy.ChannelRegistry, {:pipeline, channel_id}) do
      [{pid, _}] -> GenServer.cast(pid, {:process, entry_id})
      [] -> Logger.warning("[Pipeline] No pipeline for channel #{channel_id}")
    end
  end

  @doc "Get current throughput stats for the LiveView dashboard."
  def get_stats(channel_id) do
    case Horde.Registry.lookup(Joy.ChannelRegistry, {:pipeline, channel_id}) do
      [{pid, _}] -> GenServer.call(pid, :get_stats)
      [] -> default_stats()
    end
  end

  @doc "Reload channel config from DB (after user edits transforms/destinations)."
  def reload_config(channel_id) do
    case Horde.Registry.lookup(Joy.ChannelRegistry, {:pipeline, channel_id}) do
      [{pid, _}] -> GenServer.cast(pid, :reload_config)
      [] -> :ok
    end
  end

  @doc "Set paused state on a running pipeline. When unpausing, requeues all pending messages."
  def set_paused(channel_id, paused) do
    case Horde.Registry.lookup(Joy.ChannelRegistry, {:pipeline, channel_id}) do
      [{pid, _}] -> GenServer.cast(pid, {:set_paused, paused})
      [] -> :ok
    end
  end

  @impl true
  def init(%Joy.Channels.Channel{} = channel) do
    {:ok, %__MODULE__{channel: channel, paused: channel.paused}, {:continue, :requeue_pending}}
  end

  @impl true
  def handle_continue(:requeue_pending, %{paused: true} = state) do
    Logger.info("[Pipeline #{state.channel.id}] Channel is paused — skipping requeue on startup")
    {:noreply, state}
  end

  def handle_continue(:requeue_pending, state) do
    pending = Joy.MessageLog.list_pending(state.channel.id)
    if pending != [], do: Logger.info("[Pipeline #{state.channel.id}] Requeueing #{length(pending)} pending message(s)")
    Enum.each(pending, fn entry -> send(self(), {:cast_process, entry.id}) end)
    {:noreply, state}
  end

  @impl true
  def handle_info({:cast_process, entry_id}, state) do
    {:noreply, maybe_dispatch(entry_id, state)}
  end

  def handle_info({:dispatch_done, result}, state) do
    state =
      state
      |> apply_result(result)
      |> Map.put(:in_flight, state.in_flight - 1)
    broadcast_stats(state)
    {:noreply, maybe_drain(state)}
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def handle_cast({:process, _entry_id}, %{paused: true} = state) do
    # Message is already persisted as :pending in the DB; it will be requeued on resume.
    {:noreply, state}
  end

  def handle_cast({:process, entry_id}, state) do
    {:noreply, maybe_dispatch(entry_id, state)}
  end

  def handle_cast(:reload_config, state) do
    channel = Joy.Channels.get_channel!(state.channel.id)
    {:noreply, %{state | channel: channel, paused: channel.paused}}
  end

  def handle_cast({:set_paused, false}, state) do
    channel = Joy.Channels.get_channel!(state.channel.id)
    pending = Joy.MessageLog.list_pending(channel.id)
    if pending != [], do: Logger.info("[Pipeline #{channel.id}] Resuming: requeueing #{length(pending)} pending message(s)")
    Enum.each(pending, fn entry -> send(self(), {:cast_process, entry.id}) end)
    {:noreply, %{state | channel: channel, paused: false}}
  end

  def handle_cast({:set_paused, true}, state) do
    channel = Joy.Channels.get_channel!(state.channel.id)
    Logger.info("[Pipeline #{channel.id}] Channel paused — pipeline will hold new dispatches")
    {:noreply, %{state | channel: channel, paused: true}}
  end

  @impl true
  def handle_call(:get_stats, _from, state) do
    {:reply, stats_map(state), state}
  end

  # --------------------------------------------------------------------------
  # Dispatch helpers
  # --------------------------------------------------------------------------

  # Either start a task immediately or buffer it for later.
  defp maybe_dispatch(entry_id, state) do
    concurrency = state.channel.dispatch_concurrency || 1
    if state.in_flight < concurrency do
      spawn_task(entry_id, state.channel)
      %{state | in_flight: state.in_flight + 1}
    else
      %{state | pending_queue: :queue.in(entry_id, state.pending_queue)}
    end
  end

  # When a task slot opens, drain one item from the local queue if available.
  defp maybe_drain(state) do
    case :queue.out(state.pending_queue) do
      {:empty, _} ->
        state

      {{:value, entry_id}, rest} ->
        spawn_task(entry_id, state.channel)
        %{state | in_flight: state.in_flight + 1, pending_queue: rest}
    end
  end

  defp spawn_task(entry_id, channel) do
    pipeline_pid = self()
    Task.Supervisor.start_child(
      Joy.Channel.WorkerSupervisor.via(channel.id),
      fn -> execute_entry(entry_id, channel, pipeline_pid) end
    )
  end

  # --------------------------------------------------------------------------
  # Entry execution (runs inside a Task, never touches GenServer state directly)
  # --------------------------------------------------------------------------

  defp execute_entry(entry_id, channel, pipeline_pid) do
    entry = Joy.MessageLog.get_entry!(entry_id)

    result =
      case Joy.HL7.Parser.parse(entry.raw_hl7) do
        {:error, reason} ->
          Joy.MessageLog.mark_failed(entry_id, "Parse error: #{inspect(reason)}")
          Joy.ChannelStats.incr_failed(channel.id)
          Joy.Alerting.record_failure(channel)
          {:failed, inspect(reason)}

        {:ok, msg} ->
          transforms = Enum.filter(channel.transform_steps, & &1.enabled)

          case run_transforms(transforms, msg) do
            {:error, reason} ->
              Joy.MessageLog.mark_failed(entry_id, reason)
              Joy.ChannelStats.incr_failed(channel.id)
              Joy.Alerting.record_failure(channel)
              {:failed, reason}

            {:ok, transformed_msg} ->
              deliver_to_destinations(transformed_msg, channel.destination_configs)
              raw_out = Joy.HL7.to_string(transformed_msg)
              Joy.MessageLog.mark_processed(entry_id, raw_out)
              Joy.ChannelStats.incr_processed(channel.id)
              Joy.Alerting.record_success(channel.id)
              :processed
          end
      end

    send(pipeline_pid, {:dispatch_done, result})
  end

  defp apply_result(state, :processed) do
    %{state | processed_count: state.processed_count + 1, last_message_at: DateTime.utc_now()}
  end

  defp apply_result(state, {:failed, reason}) do
    %{state | failed_count: state.failed_count + 1, last_error: reason}
  end

  # --------------------------------------------------------------------------
  # Shared helpers
  # --------------------------------------------------------------------------

  defp run_transforms([], msg), do: {:ok, msg}
  defp run_transforms([step | rest], msg) do
    case Joy.Transform.Runner.run(step.script, msg) do
      {:ok, new_msg} -> run_transforms(rest, new_msg)
      {:error, _} = err -> err
    end
  end

  defp deliver_to_destinations(msg, dest_configs) do
    destinations =
      if msg.routes == [] do
        Enum.filter(dest_configs, & &1.enabled)
      else
        route_names = Enum.map(msg.routes, &to_string/1)
        Enum.filter(dest_configs, &(&1.enabled and routing_key(&1) in route_names))
      end

    Enum.each(destinations, fn dest ->
      case Joy.Destinations.Destination.deliver_with_retry(msg, dest) do
        :ok -> :ok
        {:error, reason} ->
          Logger.error("[Pipeline] Delivery failed to #{dest.name}: #{reason}")
      end
    end)
  end

  defp broadcast_stats(state) do
    Phoenix.PubSub.broadcast(
      Joy.PubSub,
      "channel:#{state.channel.id}:stats",
      {:stats_updated, stats_map(state)}
    )
  end

  defp stats_map(state) do
    today = Joy.ChannelStats.get_today(state.channel.id)
    %{
      processed_count: state.processed_count,
      failed_count: state.failed_count,
      last_error: state.last_error,
      last_message_at: state.last_message_at,
      paused: state.paused,
      today_received: today.received,
      today_processed: today.processed,
      today_failed: today.failed,
      retry_queue_depth: today.retry_queue_depth
    }
  end

  defp default_stats do
    %{
      processed_count: 0, failed_count: 0, last_error: nil, last_message_at: nil,
      paused: false, today_received: 0, today_processed: 0, today_failed: 0,
      retry_queue_depth: 0
    }
  end

  # For sink destinations, the routing key is config["name"] (the sink bucket identifier).
  # For all other adapters, it's the destination display name.
  defp routing_key(%{adapter: "sink", config: config}), do: to_string((config || %{})["name"] || "")
  defp routing_key(dest), do: to_string(dest.name)

  defp via(channel_id), do: {:via, Horde.Registry, {Joy.ChannelRegistry, {:pipeline, channel_id}}}
end
