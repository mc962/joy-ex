defmodule JoyWeb.DashboardLive do
  @moduledoc "Live dashboard showing channel status, throughput stats, and recent errors."
  use JoyWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    channels = Joy.Channels.list_channels()
    channel_stats = load_all_stats(channels)
    recent_errors = Joy.MessageLog.list_recent(nil, limit: 10, status: "failed")
    total_failed = Joy.MessageLog.count_all_failed()

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Joy.PubSub, "channels")
      Enum.each(channels, fn ch ->
        Phoenix.PubSub.subscribe(Joy.PubSub, "channel:#{ch.id}:stats")
      end)
    end

    {:ok,
     socket
     |> assign(:page_title, "Dashboard")
     |> assign(:channels, channels)
     |> assign(:running_ids, running_ids(channels))
     |> assign(:paused_ids, paused_ids(channels))
     |> assign(:channel_stats, channel_stats)
     |> assign(:recent_errors, recent_errors)
     |> assign(:total_failed, total_failed)
     |> assign(:expiring_certs, Joy.Channels.list_tls_expiring_soon(30))
     |> assign(:channel_groups, group_channels(channels))}
  end

  @impl true
  def handle_info({:stats_updated, stats}, socket) do
    channel_id = stats[:channel_id] || find_channel_id(stats, socket.assigns.channels)
    {:noreply, update(socket, :channel_stats, &Map.put(&1, channel_id, stats))}
  end

  def handle_info({event, _payload}, socket)
      when event in [:channel_created, :channel_deleted] do
    channels = Joy.Channels.list_channels()
    {:noreply,
     socket
     |> assign(:channels, channels)
     |> assign(:running_ids, running_ids(channels))
     |> assign(:paused_ids, paused_ids(channels))
     |> assign(:channel_groups, group_channels(channels))
     |> assign(:total_failed, Joy.MessageLog.count_all_failed())
     |> assign(:expiring_certs, Joy.Channels.list_tls_expiring_soon(30))}
  end

  def handle_info({:channel_updated, _}, socket) do
    channels = Joy.Channels.list_channels()
    {:noreply,
     socket
     |> assign(:channels, channels)
     |> assign(:paused_ids, paused_ids(channels))
     |> assign(:channel_groups, group_channels(channels))}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  @impl true
  def handle_event("start_channel", %{"id" => id}, socket) do
    if admin?(socket) do
      id = String.to_integer(id)
      channel = Joy.Channels.get_channel!(id)
      Joy.ChannelManager.start_channel(channel)
      Joy.Channels.set_started(channel, true)
      Joy.AuditLog.log(socket.assigns.current_scope.user, "channel.started", "channel", id, channel.name)
      {:noreply, assign(socket, :running_ids, MapSet.put(socket.assigns.running_ids, id))}
    else
      {:noreply, put_flash(socket, :error, "Admin access required.")}
    end
  end

  def handle_event("stop_channel", %{"id" => id}, socket) do
    if admin?(socket) do
      id = String.to_integer(id)
      channel = Joy.Channels.get_channel!(id)
      Joy.ChannelManager.stop_channel(id)
      Joy.Channels.set_started(channel, false)
      Joy.AuditLog.log(socket.assigns.current_scope.user, "channel.stopped", "channel", id, channel.name)
      {:noreply, assign(socket, :running_ids, MapSet.delete(socket.assigns.running_ids, id))}
    else
      {:noreply, put_flash(socket, :error, "Admin access required.")}
    end
  end

  def handle_event("pause_channel", %{"id" => id}, socket) do
    if admin?(socket) do
      id = String.to_integer(id)
      channel = Joy.Channels.get_channel!(id)
      Joy.ChannelManager.pause_channel(id)
      Joy.AuditLog.log(socket.assigns.current_scope.user, "channel.paused", "channel", id, channel.name)
      {:noreply, assign(socket, :paused_ids, MapSet.put(socket.assigns.paused_ids, id))}
    else
      {:noreply, put_flash(socket, :error, "Admin access required.")}
    end
  end

  def handle_event("resume_channel", %{"id" => id}, socket) do
    if admin?(socket) do
      id = String.to_integer(id)
      channel = Joy.Channels.get_channel!(id)
      Joy.ChannelManager.resume_channel(id)
      Joy.AuditLog.log(socket.assigns.current_scope.user, "channel.resumed", "channel", id, channel.name)
      {:noreply, assign(socket, :paused_ids, MapSet.delete(socket.assigns.paused_ids, id))}
    else
      {:noreply, put_flash(socket, :error, "Admin access required.")}
    end
  end

  defp running_ids(channels) do
    channels
    |> Enum.filter(&Joy.ChannelManager.channel_running?(&1.id))
    |> MapSet.new(& &1.id)
  end

  defp paused_ids(channels), do: channels |> Enum.filter(& &1.paused) |> MapSet.new(& &1.id)

  defp load_all_stats(channels) do
    Map.new(channels, fn ch ->
      stats =
        if Joy.ChannelManager.channel_running?(ch.id) do
          Joy.Channel.Pipeline.get_stats(ch.id)
        else
          %{processed_count: 0, failed_count: 0, last_error: nil, last_message_at: nil,
            paused: ch.paused, today_received: 0, today_processed: 0, today_failed: 0,
            retry_queue_depth: 0}
        end
      {ch.id, stats}
    end)
  end

  defp find_channel_id(_stats, _channels), do: nil

  # Returns [{org_or_nil, [channel]}] — orgs first (sorted by name), ungrouped last.
  defp group_channels(channels) do
    grouped = Enum.group_by(channels, & &1.organization)
    {nil_channels, org_groups} = Map.pop(grouped, nil, [])

    sorted_orgs =
      org_groups
      |> Enum.sort_by(fn {org, _} -> org.name end)

    sorted_orgs ++ (if nil_channels == [], do: [], else: [{nil, nil_channels}])
  end

  defp aggregate_today(channel_ids, channel_stats) do
    Enum.reduce(channel_ids, %{recv: 0, proc: 0, fail: 0}, fn id, acc ->
      stats = Map.get(channel_stats, id, %{})
      %{
        recv: acc.recv + (stats[:today_received] || 0),
        proc: acc.proc + (stats[:today_processed] || 0),
        fail: acc.fail + (stats[:today_failed] || 0)
      }
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} page_title={@page_title} current_scope={@current_scope}>
    <div class="space-y-6">
      <%!-- TLS cert expiry warnings --%>
      <div :if={@expiring_certs != []} class="alert alert-warning">
        <.icon name="hero-exclamation-triangle" class="w-5 h-5 shrink-0" />
        <div>
          <p class="font-medium">TLS certificate expiry warning</p>
          <p class="text-sm">
            {length(@expiring_certs)} channel{if length(@expiring_certs) == 1, do: "", else: "s"} have certificates expiring within 30 days:
            {Enum.map_join(@expiring_certs, ", ", fn ch ->
              days = if ch.tls_cert_expires_at, do: DateTime.diff(ch.tls_cert_expires_at, DateTime.utc_now(), :day), else: 0
              "#{ch.name} (#{days}d)"
            end)}.
            Update certificates on each channel's settings page.
          </p>
        </div>
      </div>

      <%!-- Summary cards --%>
      <div class="grid grid-cols-2 lg:grid-cols-4 gap-4">
        <div class="card bg-base-100 border border-base-300">
          <div class="card-body py-4 px-5">
            <p class="text-xs font-medium text-base-content/50 uppercase tracking-wider">Total Channels</p>
            <p class="text-3xl font-bold text-base-content mt-1">{length(@channels)}</p>
          </div>
        </div>
        <div class="card bg-base-100 border border-base-300">
          <div class="card-body py-4 px-5">
            <p class="text-xs font-medium text-base-content/50 uppercase tracking-wider">Running</p>
            <p class="text-3xl font-bold text-success mt-1">
              {MapSet.size(@running_ids)}
            </p>
          </div>
        </div>
        <div class="card bg-base-100 border border-base-300">
          <div class="card-body py-4 px-5">
            <p class="text-xs font-medium text-base-content/50 uppercase tracking-wider">Processed (session)</p>
            <p class="text-3xl font-bold text-base-content mt-1">
              {@channel_stats |> Map.values() |> Enum.reduce(0, &((&1[:processed_count] || 0) + &2))}
            </p>
          </div>
        </div>
        <%!-- Dead Letter Queue widget: total failed messages across all channels --%>
        <div class="card bg-base-100 border border-base-300">
          <div class="card-body py-4 px-5">
            <p class="text-xs font-medium text-base-content/50 uppercase tracking-wider">Total Failed (DLQ)</p>
            <div class="flex items-end justify-between mt-1">
              <p class="text-3xl font-bold text-error">{@total_failed}</p>
              <.link :if={@total_failed > 0} navigate={~p"/messages/failed"}
                     class="text-xs text-error/70 underline mb-1">View all</.link>
            </div>
          </div>
        </div>
      </div>

      <%!-- Channel cards --%>
      <div>
        <h2 class="text-sm font-semibold text-base-content/60 uppercase tracking-wider mb-3">Channels</h2>
        <div :if={@channels == []} class="card bg-base-100 border border-base-300">
          <div class="card-body items-center py-10 text-base-content/40">
            <.icon name="hero-arrows-right-left" class="w-8 h-8 mb-2" />
            <p class="text-sm">No channels configured yet.</p>
            <.link navigate={~p"/channels/new"} class="btn btn-primary btn-sm mt-3">
              Create your first channel
            </.link>
          </div>
        </div>
        <div class="card bg-base-100 border border-base-300 overflow-hidden">
          <div class="overflow-x-auto">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>Name</th>
                  <th>Port</th>
                  <th>Status</th>
                  <th>Today Recv / Proc / Fail</th>
                  <th>Session Fail</th>
                  <th class="text-right">Actions</th>
                </tr>
              </thead>
              <tbody :for={{org, group_channels} <- @channel_groups}>
                <%!-- Org header row --%>
                <tr :if={org} class="bg-base-200/50">
                  <td colspan="6" class="py-2 px-4">
                    <div class="flex items-center justify-between">
                      <div class="flex items-center gap-2">
                        <.icon name="hero-building-office-2" class="w-4 h-4 text-base-content/40" />
                        <.link navigate={~p"/organizations/#{org.id}"}
                               class="font-semibold text-sm hover:underline">{org.name}</.link>
                        <span class="badge badge-ghost badge-xs">{length(group_channels)}</span>
                      </div>
                      <div class="text-xs font-mono text-base-content/50">
                        <% agg = aggregate_today(Enum.map(group_channels, & &1.id), @channel_stats) %>
                        <span class="text-base-content/60">{agg.recv}</span>
                        <span class="text-base-content/30 mx-0.5">/</span>
                        <span class="text-success">{agg.proc}</span>
                        <span class="text-base-content/30 mx-0.5">/</span>
                        <span class="text-error">{agg.fail}</span>
                      </div>
                    </div>
                  </td>
                </tr>
                <%!-- Ungrouped header row --%>
                <tr :if={!org and @channel_groups != [{nil, group_channels}]} class="bg-base-200/30">
                  <td colspan="6" class="py-2 px-4">
                    <span class="text-xs font-medium text-base-content/40 uppercase tracking-wider">Ungrouped</span>
                  </td>
                </tr>
                <%!-- Channel rows --%>
                <tr :for={ch <- group_channels} class="hover">
                  <td>
                    <div>
                      <p class="font-medium">{ch.name}</p>
                      <p :if={ch.description} class="text-xs text-base-content/50">{ch.description}</p>
                    </div>
                  </td>
                  <td><span class="font-mono text-sm">{ch.mllp_port}</span></td>
                  <td>
                    <span :if={ch.id in @running_ids and ch.id not in @paused_ids}
                          class="badge badge-success badge-sm gap-1">
                      <span class="w-1.5 h-1.5 rounded-full bg-success-content animate-pulse"></span>
                      Running
                    </span>
                    <span :if={ch.id in @running_ids and ch.id in @paused_ids}
                          class="badge badge-warning badge-sm">Paused</span>
                    <span :if={ch.id not in @running_ids} class="badge badge-ghost badge-sm">Stopped</span>
                  </td>
                  <td class="text-sm font-mono">
                    <span class="text-base-content/60">{@channel_stats[ch.id][:today_received] || 0}</span>
                    <span class="text-base-content/30 mx-0.5">/</span>
                    <span class="text-success">{@channel_stats[ch.id][:today_processed] || 0}</span>
                    <span class="text-base-content/30 mx-0.5">/</span>
                    <span class="text-error">{@channel_stats[ch.id][:today_failed] || 0}</span>
                  </td>
                  <td class="text-sm font-medium text-error">{@channel_stats[ch.id][:failed_count] || 0}</td>
                  <td>
                    <div class="flex items-center justify-end gap-1">
                      <%= if @current_scope.user.is_admin do %>
                        <button :if={ch.id not in @running_ids}
                                phx-click="start_channel" phx-value-id={ch.id}
                                class="btn btn-ghost btn-xs text-success">Start</button>
                        <button :if={ch.id in @running_ids and ch.id not in @paused_ids}
                                phx-click="pause_channel" phx-value-id={ch.id}
                                class="btn btn-ghost btn-xs text-warning">Pause</button>
                        <button :if={ch.id in @running_ids and ch.id in @paused_ids}
                                phx-click="resume_channel" phx-value-id={ch.id}
                                class="btn btn-ghost btn-xs text-success">Resume</button>
                        <button :if={ch.id in @running_ids}
                                phx-click="stop_channel" phx-value-id={ch.id}
                                class="btn btn-ghost btn-xs text-error">Stop</button>
                      <% end %>
                      <.link navigate={~p"/channels/#{ch.id}"} class="btn btn-ghost btn-xs">View</.link>
                    </div>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </div>

      <%!-- Recent errors --%>
      <div :if={@recent_errors != []}>
        <div class="flex items-center justify-between mb-3">
          <h2 class="text-sm font-semibold text-base-content/60 uppercase tracking-wider">Recent Errors</h2>
          <.link :if={@total_failed > 10} navigate={~p"/messages/failed"}
                 class="text-xs text-error underline">
            View all {@total_failed} failed messages
          </.link>
        </div>
        <div class="card bg-base-100 border border-base-300 overflow-hidden">
          <div class="overflow-x-auto">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>Time</th>
                  <th>Control ID</th>
                  <th>Error</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                <tr :for={entry <- @recent_errors}>
                  <td class="text-xs text-base-content/60 whitespace-nowrap">
                    {format_dt(entry.inserted_at)}
                  </td>
                  <td class="font-mono text-xs">{entry.message_control_id || "—"}</td>
                  <td class="text-xs text-error max-w-xs truncate">{entry.error}</td>
                  <td>
                    <.link navigate={~p"/channels/#{entry.channel_id}/messages"}
                           class="btn btn-ghost btn-xs">View</.link>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </div>
    </div>
    </Layouts.app>
    """
  end

  defp format_dt(nil), do: "—"
  defp format_dt(%DateTime{} = dt), do: Calendar.strftime(dt, "%m/%d %H:%M:%S")
  defp format_dt(_), do: "—"
end
