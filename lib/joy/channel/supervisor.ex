defmodule Joy.Channel.Supervisor do
  @moduledoc """
  Per-channel OTP supervisor. Contains:
    [0] Joy.Channel.Pipeline  — processing brain
    [1] Joy.MLLP.Server       — TCP listener

  Strategy: :rest_for_one (deliberate choice over :one_for_one)
  - Pipeline [0] crash → restart Pipeline + MLLP.Server.
    The Server must reconnect to the new Pipeline instance.
  - Server [1] crash alone → restart only Server.
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
      restart: :permanent
    }
  end

  @impl true
  def init(channel) do
    children = [
      # [0] Pipeline first — crash restarts both (rest_for_one)
      {Joy.Channel.Pipeline, channel},
      # [1] Server second — crash restarts only itself
      {Joy.MLLP.Server, channel}
    ]
    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp via(channel_id), do: {:via, Registry, {Joy.ChannelRegistry, channel_id}}
end
