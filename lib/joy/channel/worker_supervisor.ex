defmodule Joy.Channel.WorkerSupervisor do
  @moduledoc """
  Per-channel Task.Supervisor for concurrent message dispatch.

  Owned by Joy.Channel.Supervisor (child [0] — before Pipeline).
  Joy.Channel.Pipeline spawns tasks here when dispatch_concurrency > 1.
  The supervisor is NOT restarted when Pipeline crashes (:rest_for_one strategy
  restarts [1] and [2] only), so orphaned tasks can complete naturally and
  send their results to a dead pid — messages silently dropped, entry requeued
  by the new Pipeline instance on startup.
  """

  def start_link(channel_id) do
    Task.Supervisor.start_link(name: via(channel_id))
  end

  def child_spec(%Joy.Channels.Channel{id: id}) do
    %{
      id: {__MODULE__, id},
      start: {__MODULE__, :start_link, [id]},
      type: :supervisor,
      restart: :permanent
    }
  end

  def via(channel_id),
    do: {:via, Horde.Registry, {Joy.ChannelRegistry, {:workers, channel_id}}}
end
