defmodule Joy.Retention.Scheduler do
  @moduledoc """
  GenServer that runs the configured daily retention purge.

  Wakes up once per hour and checks whether:
    1. schedule_enabled is true in retention_settings
    2. The current UTC hour matches schedule_hour
    3. The last purge was not already run today (prevents duplicate runs on
       multi-node deployments — all nodes check but only the first wins
       thanks to the last_purge_at timestamp).

  The actual purge runs in a Task so the GenServer is never blocked.

  # GO-TRANSLATION:
  # time.AfterFunc in a loop; cron.Job interface with a scheduled purge method.
  """

  use GenServer
  require Logger

  @check_interval :timer.hours(1)

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc "Trigger an immediate purge (respects retention_days) in the background."
  def run_now do
    GenServer.cast(__MODULE__, :run_now)
  end

  @doc "Trigger an immediate full purge (all non-pending) in the background."
  def run_now_all do
    GenServer.cast(__MODULE__, :run_now_all)
  end

  @impl true
  def init(_) do
    schedule_check()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:check, state) do
    settings = Joy.Retention.get_settings()

    if settings.schedule_enabled and should_run_now?(settings) do
      Logger.info("[Retention.Scheduler] Triggering scheduled purge at hour #{settings.schedule_hour} UTC")
      Task.start(fn -> Joy.Retention.run_purge() end)
    end

    schedule_check()
    {:noreply, state}
  end

  @impl true
  def handle_cast(:run_now, state) do
    Task.start(fn -> Joy.Retention.run_purge() end)
    {:noreply, state}
  end

  def handle_cast(:run_now_all, state) do
    Task.start(fn -> Joy.Retention.run_purge(all: true) end)
    {:noreply, state}
  end

  defp schedule_check do
    Process.send_after(self(), :check, @check_interval)
  end

  defp should_run_now?(settings) do
    now = DateTime.utc_now()
    now.hour == settings.schedule_hour and not already_ran_today?(settings)
  end

  defp already_ran_today?(%{last_purge_at: nil}), do: false

  defp already_ran_today?(%{last_purge_at: last}) do
    Date.compare(DateTime.to_date(last), Date.utc_today()) == :eq
  end
end
