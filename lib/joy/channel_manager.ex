defmodule Joy.ChannelManager do
  @moduledoc """
  Lifecycle manager for channel OTP supervision trees.

  This is a GenServer, NOT the supervisor itself (that's Joy.ChannelSupervisor,
  a DynamicSupervisor). The manager provides:
    1. Startup: loads channels with started:true from DB, starts their OTP trees
    2. Public API: start_channel/1, stop_channel/1, channel_running?/1

  Why a separate GenServer instead of calling DynamicSupervisor directly?
  DynamicSupervisor only accepts supervision-related messages. We need custom
  startup logic (DB query after Application is fully started) and a clean API.

  # GO-TRANSLATION:
  # struct with sync.Map of running channels; Start/Stop methods control goroutines.
  # OTP DynamicSupervisor provides automatic crash recovery for free;
  # Go would need manual restart logic with exponential backoff.
  """

  use GenServer
  require Logger

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Start a channel's OTP tree. Accepts a Channel struct or integer id."
  def start_channel(%Joy.Channels.Channel{} = channel),
    do: GenServer.call(__MODULE__, {:start_channel, channel})
  def start_channel(channel_id) when is_integer(channel_id),
    do: start_channel(Joy.Channels.get_channel!(channel_id))

  @doc "Stop a running channel's OTP tree by id."
  def stop_channel(channel_id), do: GenServer.call(__MODULE__, {:stop_channel, channel_id})

  @doc "Check if a channel's supervisor process is alive."
  def channel_running?(channel_id) do
    case Registry.lookup(Joy.ChannelRegistry, channel_id) do
      [{_pid, _}] -> true
      [] -> false
    end
  end

  @impl true
  def init(_opts) do
    # Defer DB access until after Application.start completes
    {:ok, %{}, {:continue, :load_started_channels}}
  end

  @impl true
  def handle_continue(:load_started_channels, state) do
    channels = Joy.Channels.list_started_channels()
    Logger.info("[ChannelManager] Auto-starting #{length(channels)} channel(s) from DB")
    Enum.each(channels, &do_start_channel/1)
    {:noreply, state}
  end

  @impl true
  def handle_call({:start_channel, channel}, _from, state) do
    if channel_running?(channel.id) do
      {:reply, {:error, :already_running}, state}
    else
      result = do_start_channel(channel)
      if match?({:ok, _}, result) do
        Phoenix.PubSub.broadcast(Joy.PubSub, "channels", {:channel_started, channel.id})
      end
      {:reply, result, state}
    end
  end

  @impl true
  def handle_call({:stop_channel, channel_id}, _from, state) do
    case Registry.lookup(Joy.ChannelRegistry, channel_id) do
      [{pid, _}] ->
        DynamicSupervisor.terminate_child(Joy.ChannelSupervisor, pid)
        Phoenix.PubSub.broadcast(Joy.PubSub, "channels", {:channel_stopped, channel_id})
        {:reply, :ok, state}
      [] ->
        {:reply, {:error, :not_running}, state}
    end
  end

  defp do_start_channel(channel) do
    case DynamicSupervisor.start_child(Joy.ChannelSupervisor, {Joy.Channel.Supervisor, channel}) do
      {:ok, _pid} = ok ->
        Logger.info("[ChannelManager] Started channel #{channel.id} (#{channel.name}) on :#{channel.mllp_port}")
        ok
      {:error, reason} = err ->
        Logger.error("[ChannelManager] Failed to start channel #{channel.id}: #{inspect(reason)}")
        err
    end
  end
end
