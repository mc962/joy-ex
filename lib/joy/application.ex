defmodule Joy.Application do
  @moduledoc """
  OTP Application entry point.

  Supervision tree (all :one_for_one at the top level — each child is independent):

    JoyWeb.Telemetry          — Phoenix metrics
    Joy.Repo                  — Ecto database connection pool
    DNSCluster                — distributed node discovery (connects Erlang nodes)
    Phoenix.PubSub            — real-time pub/sub for LiveView dashboard updates (pg adapter, cluster-aware)
    Joy.ChannelRegistry       — Horde.Registry: distributed registry of channel supervisor + pipeline PIDs
    Joy.TransformSupervisor   — Task.Supervisor for sandboxed transform script evaluation (node-local)
    Joy.MLLP.ConnectionSup    — DynamicSupervisor for all active MLLP TCP connections (node-local)
    Joy.ChannelSupervisor     — Horde.DynamicSupervisor: distributes per-channel OTP trees across cluster
    Joy.ChannelManager        — GenServer: starts channels on boot, manages runtime lifecycle
    JoyWeb.Endpoint           — Phoenix HTTP/WebSocket endpoint (last, after all infrastructure)

  Clustering strategy:
  DNSCluster handles Erlang node discovery and connection. Horde.Registry and
  Horde.DynamicSupervisor use members: :auto, which hooks into :nodeup/:nodedown
  events to automatically sync cluster membership. Each channel's OTP tree runs
  on exactly one node; if that node dies, Horde restarts it on a healthy node.

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

      # Distributed registry: maps channel_id → channel supervisor PID, and
      # {:pipeline, channel_id} → pipeline PID. Horde.Registry is cluster-aware —
      # lookups work from any node regardless of where the process actually runs.
      {Horde.Registry, keys: :unique, name: Joy.ChannelRegistry, members: :auto},

      # Isolated Task.Supervisor for evaluating user-written transform scripts.
      # Node-local intentionally: transform tasks are ephemeral, not worth distributing.
      {Task.Supervisor, name: Joy.TransformSupervisor},

      # ETS-backed per-channel throughput counters (received/processed/failed today).
      # Reset on node restart — acceptable for live "today" metrics.
      Joy.ChannelStats,

      # Tracks consecutive failures per channel; fires email/webhook alerts on threshold.
      Joy.Alerting,

      # Checks TLS certificate expiry daily; fires alerts for certs expiring within 30 days.
      Joy.CertMonitor,

      # Runs the scheduled message log purge at the configured UTC hour.
      Joy.Retention.Scheduler,

      # In-memory message sink for testing destinations. Capped ring buffer per
      # named sink; messages are inspectable via the Sinks UI at /tools/sinks.
      Joy.Sinks,

      # All MLLP TCP connection handlers live here, globally.
      # Node-local intentionally: TCP connections are inherently node-local.
      {DynamicSupervisor, name: Joy.MLLP.ConnectionSupervisor, strategy: :one_for_one},

      # Distributed dynamic supervisor for per-channel OTP trees.
      # Horde distributes channel supervisor trees across cluster nodes and
      # automatically restarts them on a healthy node if the owning node dies.
      {Horde.DynamicSupervisor, name: Joy.ChannelSupervisor, strategy: :one_for_one, members: :auto},

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
