defmodule Joy.Application do
  @moduledoc """
  OTP Application entry point.

  Supervision tree (all :one_for_one at the top level — each child is independent):

    JoyWeb.Telemetry          — Phoenix metrics
    Joy.Repo                  — Ecto database connection pool
    DNSCluster                — distributed node discovery
    Phoenix.PubSub            — real-time pub/sub for LiveView dashboard updates
    Joy.ChannelRegistry       — Registry tracking live channel supervisor PIDs by channel_id
    Joy.PipelineRegistry      — Registry tracking live pipeline GenServer PIDs by channel_id
    Joy.TransformSupervisor   — Task.Supervisor for sandboxed transform script evaluation
    Joy.MLLP.ConnectionSup    — DynamicSupervisor for all active MLLP TCP connections
    Joy.ChannelSupervisor     — DynamicSupervisor for per-channel supervisor subtrees
    Joy.ChannelManager        — GenServer: starts channels on boot, manages runtime lifecycle
    JoyWeb.Endpoint           — Phoenix HTTP/WebSocket endpoint (last, after all infrastructure)

  Why :one_for_one at the top?
  Each child serves a completely different function. A crashed Repo should not restart
  the PubSub, and a crashed Endpoint should not restart the ChannelManager. All children
  are independent enough that :one_for_one is the correct strategy.

  # GO-TRANSLATION: In Go, the equivalent is a main() function that starts each
  # component as a goroutine under an errgroup. The ordering of Start calls matters
  # for the same dependency reasons (DB before channel manager, etc.)
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      JoyWeb.Telemetry,
      Joy.Repo,
      {DNSCluster, query: Application.get_env(:joy, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Joy.PubSub},

      # Registry: maps channel_id → channel supervisor PID (for start/stop from UI)
      {Registry, keys: :unique, name: Joy.ChannelRegistry},

      # Registry: maps channel_id → pipeline GenServer PID (for sending messages)
      {Registry, keys: :unique, name: Joy.PipelineRegistry},

      # Isolated Task.Supervisor for evaluating user-written transform scripts.
      # Crashes in transform tasks are contained here — channel pipeline is unaffected.
      {Task.Supervisor, name: Joy.TransformSupervisor},

      # In-memory message sink for testing destinations. Capped ring buffer per
      # named sink; messages are inspectable via the Sinks UI at /tools/sinks.
      Joy.Sinks,

      # All MLLP TCP connection handlers live here, globally.
      # Using a global supervisor (rather than per-channel) simplifies the tree
      # and means connection crashes never bubble up to the channel supervisor.
      {DynamicSupervisor, name: Joy.MLLP.ConnectionSupervisor, strategy: :one_for_one},

      # Top-level dynamic supervisor for per-channel supervisor subtrees.
      # Each subtree is {Joy.Channel.Supervisor, channel} which itself uses :rest_for_one.
      {DynamicSupervisor, name: Joy.ChannelSupervisor, strategy: :one_for_one},

      # Control-plane GenServer: on startup loads channels with started:true from DB
      # and starts their supervisor trees. Exposes start_channel/stop_channel API.
      Joy.ChannelManager,

      JoyWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Joy.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    JoyWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
