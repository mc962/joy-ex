defmodule Joy.Channel.Pipeline do
  @moduledoc """
  The processing brain of a channel.

  Responsibilities:
    1. Holds channel config (transforms, destinations) in state — no DB hit per message
    2. Requeues :pending log entries on startup (crash recovery)
    3. Processes messages via GenServer.cast (async, one at a time per channel)
    4. Runs each enabled transform in order via Joy.Transform.Runner
    5. Delivers to all enabled destinations (or only routed ones)
    6. Tracks throughput stats; broadcasts to PubSub for LiveView dashboard

  Why sequential (single GenServer) instead of concurrent Task pool?
  MLLP ACK-based flow means senders naturally serialize messages per connection.
  Single GenServer ensures ordered processing and simple state management.

  # GO-TRANSLATION:
  # struct with sync.Mutex protecting config + stats; goroutine reading from chan Message.
  # The GenServer mailbox IS the channel; no explicit chan or mutex needed.
  # State mutation via message passing replaces mutex-protected struct updates.
  """

  use GenServer
  require Logger

  defstruct channel: nil, processed_count: 0, failed_count: 0,
            last_error: nil, last_message_at: nil

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

  @impl true
  def init(%Joy.Channels.Channel{} = channel) do
    {:ok, %__MODULE__{channel: channel}, {:continue, :requeue_pending}}
  end

  @impl true
  def handle_continue(:requeue_pending, state) do
    pending = Joy.MessageLog.list_pending(state.channel.id)
    if pending != [], do: Logger.info("[Pipeline #{state.channel.id}] Requeueing #{length(pending)} pending message(s)")
    Enum.each(pending, fn entry -> send(self(), {:cast_process, entry.id}) end)
    {:noreply, state}
  end

  @impl true
  def handle_info({:cast_process, entry_id}, state) do
    {:noreply, do_process(entry_id, state)}
  end

  @impl true
  def handle_cast({:process, entry_id}, state) do
    {:noreply, do_process(entry_id, state)}
  end

  @impl true
  def handle_cast(:reload_config, state) do
    channel = Joy.Channels.get_channel!(state.channel.id)
    {:noreply, %{state | channel: channel}}
  end

  @impl true
  def handle_call(:get_stats, _from, state) do
    {:reply, stats_map(state), state}
  end

  defp do_process(entry_id, state) do
    entry = Joy.MessageLog.get_entry!(entry_id)

    case Joy.HL7.Parser.parse(entry.raw_hl7) do
      {:error, reason} ->
        Joy.MessageLog.mark_failed(entry_id, "Parse error: #{inspect(reason)}")
        new_state = %{state | failed_count: state.failed_count + 1, last_error: inspect(reason)}
        broadcast_stats(new_state)
        new_state

      {:ok, msg} ->
        transforms = Enum.filter(state.channel.transform_steps, & &1.enabled)

        case run_transforms(transforms, msg) do
          {:error, reason} ->
            Joy.MessageLog.mark_failed(entry_id, reason)
            new_state = %{state | failed_count: state.failed_count + 1, last_error: reason}
            broadcast_stats(new_state)
            new_state

          {:ok, transformed_msg} ->
            deliver_to_destinations(transformed_msg, state.channel.destination_configs)
            raw_out = Joy.HL7.to_string(transformed_msg)
            Joy.MessageLog.mark_processed(entry_id, raw_out)
            new_state = %{state |
              processed_count: state.processed_count + 1,
              last_message_at: DateTime.utc_now()
            }
            broadcast_stats(new_state)
            new_state
        end
    end
  end

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
    %{
      processed_count: state.processed_count,
      failed_count: state.failed_count,
      last_error: state.last_error,
      last_message_at: state.last_message_at
    }
  end

  defp default_stats, do: %{processed_count: 0, failed_count: 0, last_error: nil, last_message_at: nil}

  # For sink destinations, the routing key is config["name"] (the sink bucket identifier).
  # For all other adapters, it's the destination display name.
  defp routing_key(%{adapter: "sink", config: config}), do: to_string((config || %{})["name"] || "")
  defp routing_key(dest), do: to_string(dest.name)

  defp via(channel_id), do: {:via, Horde.Registry, {Joy.ChannelRegistry, {:pipeline, channel_id}}}
end
