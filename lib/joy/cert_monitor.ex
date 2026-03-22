defmodule Joy.CertMonitor do
  @moduledoc """
  Checks TLS certificate expiry for all TLS-enabled channels once per day.
  Fires alerts (email + webhook) for certs expiring within the warning window
  using the same delivery path as Joy.Alerting.

  State: stateless — ETS is not needed because the check result is derived
  entirely from the database on each run.

  # GO-TRANSLATION:
  # time.AfterFunc loop or cron-style goroutine. GenServer with
  # Process.send_after replaces time.Sleep / time.NewTicker.
  """

  use GenServer
  require Logger

  @check_interval :timer.hours(24)
  @warn_days 30

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_) do
    # Run immediately on startup so operators see warnings on boot, not 24h later
    send(self(), :check)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:check, state) do
    check_expiring_certs()
    Process.send_after(self(), :check, @check_interval)
    {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  # ---------- private ----------

  defp check_expiring_certs do
    channels = Joy.Channels.list_tls_expiring_soon(@warn_days)

    Enum.each(channels, fn channel ->
      days = DateTime.diff(channel.tls_cert_expires_at, DateTime.utc_now(), :day)
      expiry_date = channel.tls_cert_expires_at |> DateTime.to_date() |> Date.to_iso8601()

      Logger.warning("[CertMonitor] Channel #{channel.id} (#{channel.name}) TLS cert expires in #{days} days (#{expiry_date})")

      if channel.alert_enabled do
        subject = "[Joy] TLS cert expiring in #{days} days — #{channel.name}"
        message =
          "Channel '#{channel.name}' (MLLP port #{channel.mllp_port}) TLS certificate expires " <>
          "in #{days} day(s) on #{expiry_date}. " <>
          "Renew the certificate and update it on the channel settings page before expiry to avoid connection failures."

        Joy.Alerting.send_direct(channel, subject, message)
      end
    end)
  end
end
