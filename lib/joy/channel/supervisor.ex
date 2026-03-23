defmodule Joy.Channel.Supervisor do
  @moduledoc """
  Per-channel OTP supervisor. Contains:
    [0] Joy.Channel.WorkerSupervisor — Task.Supervisor for concurrent dispatch
    [1] Joy.Channel.Pipeline         — processing brain
    [2] Joy.MLLP.Server              — TCP listener

  Strategy: :rest_for_one (deliberate choice over :one_for_one)
  - WorkerSupervisor [0] crash → restart everything (rare; Task.Supervisor is very stable).
  - Pipeline [1] crash → restart Pipeline + MLLP.Server.
    WorkerSupervisor is NOT restarted; orphaned tasks complete and their results
    are silently dropped (entries are requeued by the new Pipeline on startup).
  - Server [2] crash alone → restart only Server.
    Pipeline state (counters, config) is preserved.

  Registered in Joy.ChannelRegistry so Joy.ChannelManager can find and
  terminate it by channel_id.

  # GO-TRANSLATION:
  # context.Context + cancel per channel; dependent goroutines cancelled together.
  # No Go equivalent to :rest_for_one — manual restart of dependents needed.
  """

  use Supervisor

  def start_link(%Joy.Channels.Channel{} = channel) do
    Supervisor.start_link(__MODULE__, channel, name: via(channel.id))
  end

  def child_spec(%Joy.Channels.Channel{id: id} = channel) do
    %{
      id: {__MODULE__, id},
      start: {__MODULE__, :start_link, [channel]},
      type: :supervisor,
      restart: :permanent,
      # Inspected by Joy.PinnedDistribution: nil = uniform hash; string = target node name.
      pinned_node: channel.pinned_node
    }
  end

  @impl true
  def init(channel) do
    children = [
      # [0] WorkerSupervisor first — Task.Supervisor for async dispatch
      {Joy.Channel.WorkerSupervisor, channel},
      # [1] Pipeline second — crash restarts Pipeline + Server (rest_for_one)
      {Joy.Channel.Pipeline, channel},
      # [2] Server third — crash restarts only itself
      {Joy.MLLP.Server, channel}
    ]
    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp via(channel_id), do: {:via, Horde.Registry, {Joy.ChannelRegistry, channel_id}}
end
