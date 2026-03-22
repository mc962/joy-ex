defmodule JoyWeb.Messages.FailedLive do
  @moduledoc "Global dead letter queue: all :failed message log entries across all channels."
  use JoyWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    entries = Joy.MessageLog.list_all_failed(limit: 200)
    channels = Joy.Channels.list_channels()
    channel_map = Map.new(channels, &{&1.id, &1})

    {:ok,
     socket
     |> assign(:page_title, "Failed Messages")
     |> assign(:channel_map, channel_map)
     |> assign(:selected_entry, nil)
     |> stream(:entries, entries)}
  end

  @impl true
  def handle_event("select_entry", %{"id" => id}, socket) do
    entry = Joy.MessageLog.get_entry!(String.to_integer(id))
    {:noreply, assign(socket, :selected_entry, entry)}
  end

  def handle_event("close_detail", _, socket) do
    {:noreply, assign(socket, :selected_entry, nil)}
  end

  def handle_event("retry", %{"id" => id}, socket) do
    entry = Joy.MessageLog.get_entry!(String.to_integer(id))

    if Joy.ChannelManager.channel_running?(entry.channel_id) do
      {:ok, new_entry} = Joy.MessageLog.retry_entry(entry)
      Joy.Channel.Pipeline.process_async(entry.channel_id, new_entry.id)
      # Remove the retried entry from the stream
      {:noreply,
       socket
       |> put_flash(:info, "Message requeued")
       |> assign(:selected_entry, nil)
       |> stream_delete(:entries, entry)}
    else
      {:noreply, put_flash(socket, :error, "Channel is not running")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} page_title={@page_title} current_scope={@current_scope}>
    <div class="space-y-4">
      <div class="flex items-center justify-between">
        <div>
          <h1 class="text-lg font-bold">Failed Messages</h1>
          <p class="text-sm text-base-content/50 mt-0.5">
            All :failed message log entries across all channels. Retry individually below.
          </p>
        </div>
        <.link navigate={~p"/"} class="btn btn-ghost btn-sm">
          <.icon name="hero-arrow-left" class="w-4 h-4" /> Dashboard
        </.link>
      </div>

      <div class={"flex gap-4 #{if @selected_entry, do: "items-start", else: ""}"}>
        <div class={"card bg-base-100 border border-base-300 overflow-hidden flex-1 min-w-0 #{if @selected_entry, do: "w-1/2", else: "w-full"}"}>
          <div class="overflow-x-auto">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>Channel</th>
                  <th>Time</th>
                  <th>Control ID</th>
                  <th>Type</th>
                  <th>Error</th>
                  <th></th>
                </tr>
              </thead>
              <tbody id="failed-entries" phx-update="stream">
                <tr :for={{dom_id, entry} <- @streams.entries}
                    id={dom_id}
                    phx-click="select_entry"
                    phx-value-id={entry.id}
                    class={"cursor-pointer hover #{if @selected_entry && @selected_entry.id == entry.id, do: "bg-primary/10", else: ""}"}>
                  <td class="text-sm font-medium">
                    {get_channel_name(@channel_map, entry.channel_id)}
                  </td>
                  <td class="text-xs text-base-content/60 whitespace-nowrap">
                    {format_dt(entry.inserted_at)}
                  </td>
                  <td class="font-mono text-xs">{entry.message_control_id || "—"}</td>
                  <td class="text-xs font-mono">{entry.message_type || "—"}</td>
                  <td class="text-xs text-error max-w-xs truncate">{entry.error}</td>
                  <td>
                    <.link navigate={~p"/channels/#{entry.channel_id}/messages"}
                           class="btn btn-ghost btn-xs">Log</.link>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
          <div class="p-4 border-t border-base-300 text-xs text-base-content/40 text-center">
            Showing up to 200 most recent failures. Use channel message logs to retry in bulk.
          </div>
        </div>

        <%!-- Detail panel --%>
        <div :if={@selected_entry} class="card bg-base-100 border border-base-300 w-96 shrink-0">
          <div class="card-body p-4 space-y-4">
            <div class="flex items-center justify-between">
              <h3 class="font-semibold text-sm">Message Detail</h3>
              <button phx-click="close_detail" class="btn btn-ghost btn-xs btn-square">
                <.icon name="hero-x-mark" class="w-4 h-4" />
              </button>
            </div>

            <div class="space-y-1 text-xs">
              <div class="flex justify-between">
                <span class="text-base-content/50">Channel</span>
                <span class="font-medium">
                  {get_channel_name(@channel_map, @selected_entry.channel_id)}
                </span>
              </div>
              <div class="flex justify-between">
                <span class="text-base-content/50">Control ID</span>
                <span class="font-mono">{@selected_entry.message_control_id || "—"}</span>
              </div>
              <div class="flex justify-between">
                <span class="text-base-content/50">Type</span>
                <span class="font-mono">{@selected_entry.message_type || "—"}</span>
              </div>
              <div :if={@selected_entry.patient_id} class="flex justify-between">
                <span class="text-base-content/50">Patient ID</span>
                <span class="font-mono">{@selected_entry.patient_id}</span>
              </div>
              <div class="flex justify-between">
                <span class="text-base-content/50">Received</span>
                <span>{format_dt(@selected_entry.inserted_at)}</span>
              </div>
            </div>

            <button phx-click="retry" phx-value-id={@selected_entry.id}
                    class="btn btn-sm btn-warning w-full">
              <.icon name="hero-arrow-path" class="w-4 h-4" /> Retry
            </button>

            <div :if={@selected_entry.error} class="rounded bg-error/10 border border-error/20 p-3">
              <p class="text-xs font-semibold text-error mb-1">Error</p>
              <pre class="text-xs text-error whitespace-pre-wrap">{@selected_entry.error}</pre>
            </div>

            <div>
              <p class="text-xs font-semibold text-base-content/50 mb-1">Raw HL7</p>
              <pre class="text-xs font-mono bg-base-200 rounded p-2 overflow-auto max-h-48 whitespace-pre-wrap">{@selected_entry.raw_hl7}</pre>
            </div>
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

  defp get_channel_name(channel_map, channel_id) do
    case Map.get(channel_map, channel_id) do
      nil -> "Channel #{channel_id}"
      ch -> ch.name
    end
  end
end
