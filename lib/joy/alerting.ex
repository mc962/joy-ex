defmodule Joy.Alerting do
  @moduledoc """
  Tracks consecutive failures per channel and fires alerts when a threshold is crossed.
  Also provides send_direct/3 for non-threshold alerts (e.g. cert expiry from CertMonitor).

  State is ETS-backed (lost on restart, acceptable — alert storms after a cold restart
  are rare and low-severity compared to missing an alert). Each channel has:
    - consecutive_failures: integer, resets to 0 on any success
    - last_alert_at: DateTime | nil, enforces the per-channel cooldown

  Alert delivery:
    - Email via Joy.Mailer when alert_email is configured
    - HTTP webhook POST when alert_webhook_url is configured

  Called from Joy.Channel.Pipeline after mark_failed / mark_processed.
  send_direct/3 called from Joy.CertMonitor for cert expiry warnings.

  # GO-TRANSLATION:
  # sync.Map[channelID]alertState; goroutine per alert delivery.
  # ETS :update_counter replaces atomic.AddInt32; cooldown via time.Since(lastAlert).
  """

  use GenServer
  require Logger
  alias Joy.Mailer

  @table :channel_alerting

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc "Record a failure for a channel. Fires an alert if threshold is exceeded."
  def record_failure(%Joy.Channels.Channel{} = channel) do
    if not channel.alert_enabled do
      :ok
    else
      count = bump_failures(channel.id)
      if count >= channel.alert_threshold do
        maybe_send_alert(channel, count)
      end
      :ok
    end
  end

  @doc "Record a success for a channel. Resets the consecutive failure counter."
  def record_success(channel_id) do
    :ets.insert(@table, {channel_id, 0, get_last_alert_at(channel_id)})
    :ok
  end

  @doc """
  Send an alert directly, bypassing the threshold/ETS mechanism.
  Used for cert expiry warnings and other time-based alerts.
  Respects alert_enabled, alert_email, and alert_webhook_url settings.
  """
  def send_direct(%Joy.Channels.Channel{} = channel, subject, message) do
    GenServer.cast(__MODULE__, {:send_direct, channel, subject, message})
  end

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    {:ok, %{}}
  end

  @impl true
  def handle_cast({:send_direct, channel, subject, message}, state) do
    Logger.warning("[Alerting] Direct alert for channel #{channel.id}: #{subject}")
    deliver(channel, subject, message)
    {:noreply, state}
  end

  # ---------- private ----------

  defp bump_failures(channel_id) do
    ensure_row(channel_id)
    :ets.update_counter(@table, channel_id, {2, 1})
  end

  defp get_last_alert_at(channel_id) do
    case :ets.lookup(@table, channel_id) do
      [{_, _, ts}] -> ts
      [] -> nil
    end
  end

  defp ensure_row(channel_id) do
    case :ets.lookup(@table, channel_id) do
      [] -> :ets.insert_new(@table, {channel_id, 0, nil})
      _ -> :ok
    end
  end

  defp maybe_send_alert(channel, count) do
    last_alert = get_last_alert_at(channel.id)
    cooldown_secs = (channel.alert_cooldown_minutes || 60) * 60
    now = DateTime.utc_now()

    within_cooldown =
      last_alert != nil and
        DateTime.diff(now, last_alert, :second) < cooldown_secs

    if not within_cooldown do
      # Update last_alert_at before firing to prevent duplicate sends under concurrent pressure.
      :ets.insert(@table, {channel.id, count, now})
      subject = "[Joy Alert] #{channel.name} — #{channel.alert_threshold} consecutive failures"
      message = "Channel '#{channel.name}' has #{count} consecutive failures on port #{channel.mllp_port}."
      Logger.warning("[Alerting] #{message}")
      deliver(channel, subject, message)
    end
  end

  defp deliver(channel, subject, message) do
    if channel.alert_email && channel.alert_email != "" do
      send_email(channel.alert_email, subject, message)
    end

    if channel.alert_webhook_url && channel.alert_webhook_url != "" do
      send_webhook(channel, subject, message)
    end
  end

  defp send_email(to, subject, body) do
    import Swoosh.Email

    email =
      new()
      |> to(to)
      |> from({"Joy HL7 Engine", "noreply@joy.local"})
      |> subject(subject)
      |> text_body(body <> "\n\nLog in to Joy to review and take action.")

    case Mailer.deliver(email) do
      {:ok, _} ->
        Logger.info("[Alerting] Alert email sent to #{to}")
      {:error, reason} ->
        Logger.error("[Alerting] Failed to send alert email: #{inspect(reason)}")
    end
  end

  defp send_webhook(channel, subject, message) do
    payload = Jason.encode!(%{
      channel_id:   channel.id,
      channel_name: channel.name,
      mllp_port:    channel.mllp_port,
      subject:      subject,
      message:      message,
      timestamp:    DateTime.utc_now() |> DateTime.to_iso8601()
    })

    case Req.post(channel.alert_webhook_url,
           body: payload,
           headers: [{"content-type", "application/json"}],
           receive_timeout: 5_000) do
      {:ok, %{status: status}} when status in 200..299 ->
        Logger.info("[Alerting] Webhook alert delivered for channel #{channel.id}")
      {:ok, %{status: status}} ->
        Logger.warning("[Alerting] Webhook returned #{status} for channel #{channel.id}")
      {:error, reason} ->
        Logger.error("[Alerting] Webhook delivery failed for channel #{channel.id}: #{inspect(reason)}")
    end
  end
end
