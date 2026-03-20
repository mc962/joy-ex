defmodule JoyWeb.DashboardLive do
  @moduledoc "Live dashboard showing channel status, throughput stats, and recent errors."
  use JoyWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    channels = Joy.Channels.list_channels()
    channel_stats = load_all_stats(channels)
    recent_errors = Joy.MessageLog.list_recent(nil, limit: 10, status: "failed")

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
     |> assign(:channel_stats, channel_stats)
     |> assign(:recent_errors, recent_errors)}
  end

  @impl true
  def handle_info({:stats_updated, stats}, socket) do
    channel_id = stats[:channel_id] || find_channel_id(stats, socket.assigns.channels)
    {:noreply, update(socket, :channel_stats, &Map.put(&1, channel_id, stats))}
  end

  def handle_info({event, _payload}, socket)
      when event in [:channel_created, :channel_updated, :channel_deleted] do
    channels = Joy.Channels.list_channels()
    {:noreply, assign(socket, :channels, channels)}
  end

  def handle_info({:channel_started, _id}, socket) do
    channels = Joy.Channels.list_channels()
    channel_stats = load_all_stats(channels)
    {:noreply, assign(socket, channels: channels, channel_stats: channel_stats)}
  end

  def handle_info({:channel_stopped, _id}, socket) do
    channels = Joy.Channels.list_channels()
    channel_stats = load_all_stats(channels)
    {:noreply, assign(socket, channels: channels, channel_stats: channel_stats)}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  @impl true
  def handle_event("start_channel", %{"id" => id}, socket) do
    id = String.to_integer(id)
    channel = Joy.Channels.get_channel!(id)
    Joy.ChannelManager.start_channel(channel)
    Joy.Channels.set_started(channel, true)
    channels = Joy.Channels.list_channels()
    {:noreply, assign(socket, channels: channels, channel_stats: load_all_stats(channels))}
  end

  def handle_event("stop_channel", %{"id" => id}, socket) do
    id = String.to_integer(id)
    channel = Joy.Channels.get_channel!(id)
    Joy.ChannelManager.stop_channel(id)
    Joy.Channels.set_started(channel, false)
    channels = Joy.Channels.list_channels()
    {:noreply, assign(socket, channels: channels, channel_stats: load_all_stats(channels))}
  end

  defp load_all_stats(channels) do
    Map.new(channels, fn ch ->
      stats =
        if Joy.ChannelManager.channel_running?(ch.id) do
          Joy.Channel.Pipeline.get_stats(ch.id)
        else
          %{processed_count: 0, failed_count: 0, last_error: nil, last_message_at: nil}
        end
      {ch.id, stats}
    end)
  end

  defp find_channel_id(_stats, _channels), do: nil

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} page_title={@page_title} current_scope={@current_scope}>
    <div class="space-y-6">
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
              {Enum.count(@channels, &Joy.ChannelManager.channel_running?(&1.id))}
            </p>
          </div>
        </div>
        <div class="card bg-base-100 border border-base-300">
          <div class="card-body py-4 px-5">
            <p class="text-xs font-medium text-base-content/50 uppercase tracking-wider">Processed</p>
            <p class="text-3xl font-bold text-base-content mt-1">
              {@channel_stats |> Map.values() |> Enum.reduce(0, &(&1.processed_count + &2))}
            </p>
          </div>
        </div>
        <div class="card bg-base-100 border border-base-300">
          <div class="card-body py-4 px-5">
            <p class="text-xs font-medium text-base-content/50 uppercase tracking-wider">Recent Errors</p>
            <p class="text-3xl font-bold text-error mt-1">{length(@recent_errors)}</p>
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
        <div class="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-3 gap-4">
          <div :for={ch <- @channels} class="card bg-base-100 border border-base-300 hover:border-primary/30 transition-colors">
            <div class="card-body p-5">
              <div class="flex items-start justify-between gap-2">
                <div class="min-w-0">
                  <h3 class="font-semibold text-base-content truncate">{ch.name}</h3>
                  <p class="text-xs text-base-content/50 mt-0.5">Port {ch.mllp_port}</p>
                </div>
                <div class="flex items-center gap-1.5 shrink-0">
                  <span :if={Joy.ChannelManager.channel_running?(ch.id)}
                        class="badge badge-success badge-sm gap-1">
                    <span class="w-1.5 h-1.5 rounded-full bg-success-content animate-pulse"></span>
                    Running
                  </span>
                  <span :if={!Joy.ChannelManager.channel_running?(ch.id)}
                        class="badge badge-ghost badge-sm">Stopped</span>
                </div>
              </div>

              <div class="flex gap-4 mt-3 text-xs text-base-content/60">
                <span>
                  <span class="font-medium text-success">{@channel_stats[ch.id][:processed_count] || 0}</span>
                  processed
                </span>
                <span>
                  <span class="font-medium text-error">{@channel_stats[ch.id][:failed_count] || 0}</span>
                  failed
                </span>
              </div>

              <div class="flex items-center gap-2 mt-4">
                <button
                  :if={!Joy.ChannelManager.channel_running?(ch.id)}
                  phx-click="start_channel"
                  phx-value-id={ch.id}
                  class="btn btn-success btn-xs flex-1"
                >
                  Start
                </button>
                <button
                  :if={Joy.ChannelManager.channel_running?(ch.id)}
                  phx-click="stop_channel"
                  phx-value-id={ch.id}
                  class="btn btn-ghost btn-xs flex-1"
                >
                  Stop
                </button>
                <.link navigate={~p"/channels/#{ch.id}"} class="btn btn-ghost btn-xs">View</.link>
              </div>
            </div>
          </div>
        </div>
      </div>

      <%!-- Recent errors --%>
      <div :if={@recent_errors != []}>
        <h2 class="text-sm font-semibold text-base-content/60 uppercase tracking-wider mb-3">Recent Errors</h2>
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
