defmodule JoyWeb.MessageLog.IndexLive do
  @moduledoc "Real-time message log viewer for a channel with search and bulk retry."
  use JoyWeb, :live_view

  @impl true
  def mount(%{"id" => ch_id}, _session, socket) do
    channel = Joy.Channels.get_channel!(String.to_integer(ch_id))
    entries = Joy.MessageLog.list_recent(channel.id, limit: 100)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Joy.PubSub, "message_log:#{channel.id}")
    end

    {:ok,
     socket
     |> assign(:page_title, "Messages · #{channel.name}")
     |> assign(:channel, channel)
     |> assign(:filter_status, "all")
     |> assign(:search_type, "")
     |> assign(:search_patient, "")
     |> assign(:selected_entry, nil)
     |> assign(:failed_count, count_failed(channel.id))
     |> stream(:entries, entries)}
  end

  @impl true
  def handle_info({:new_entry, entry}, socket) do
    socket =
      if socket.assigns.selected_entry && socket.assigns.selected_entry.id == entry.id do
        assign(socket, :selected_entry, entry)
      else
        socket
      end

    socket =
      if entry.status == "failed" do
        update(socket, :failed_count, &(&1 + 1))
      else
        socket
      end

    {:noreply, stream_insert(socket, :entries, entry, at: 0)}
  end
  def handle_info(_, socket), do: {:noreply, socket}

  @impl true
  def handle_event("filter", %{"status" => status}, socket) do
    entries = load_entries(socket.assigns.channel.id, status, socket.assigns.search_type, socket.assigns.search_patient)
    {:noreply,
     socket
     |> assign(:filter_status, status)
     |> stream(:entries, entries, reset: true)}
  end

  def handle_event("search", %{"type" => type, "patient" => patient}, socket) do
    entries = load_entries(socket.assigns.channel.id, socket.assigns.filter_status, type, patient)
    {:noreply,
     socket
     |> assign(:search_type, type)
     |> assign(:search_patient, patient)
     |> stream(:entries, entries, reset: true)}
  end

  def handle_event("select_entry", %{"id" => id}, socket) do
    entry = Joy.MessageLog.get_entry!(String.to_integer(id))
    {:noreply, assign(socket, :selected_entry, entry)}
  end

  def handle_event("close_detail", _, socket) do
    {:noreply, assign(socket, :selected_entry, nil)}
  end

  def handle_event("retry", %{"id" => id}, socket) do
    entry = Joy.MessageLog.get_entry!(String.to_integer(id))

    if Joy.ChannelManager.channel_running?(socket.assigns.channel.id) do
      {:ok, new_entry} = Joy.MessageLog.retry_entry(entry)
      Joy.Channel.Pipeline.process_async(socket.assigns.channel.id, new_entry.id)
      {:noreply,
       socket
       |> put_flash(:info, "Message requeued")
       |> assign(:selected_entry, nil)}
    else
      {:noreply, put_flash(socket, :error, "Channel is not running")}
    end
  end

  def handle_event("retry_all_failed", _, socket) do
    if Joy.ChannelManager.channel_running?(socket.assigns.channel.id) do
      {:ok, count} = Joy.MessageLog.retry_all_failed(socket.assigns.channel.id)
      entries = load_entries(socket.assigns.channel.id, socket.assigns.filter_status,
                             socket.assigns.search_type, socket.assigns.search_patient)
      {:noreply,
       socket
       |> put_flash(:info, "Requeued #{count} message(s)")
       |> assign(:failed_count, count_failed(socket.assigns.channel.id))
       |> stream(:entries, entries, reset: true)}
    else
      {:noreply, put_flash(socket, :error, "Channel is not running")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} page_title={@page_title} current_scope={@current_scope}>
    <div class="space-y-4">
      <div class="flex items-center justify-between flex-wrap gap-2">
        <.link navigate={~p"/channels/#{@channel.id}"} class="btn btn-ghost btn-sm">
          <.icon name="hero-arrow-left" class="w-4 h-4" /> {@channel.name}
        </.link>
        <div class="flex items-center gap-2 flex-wrap">
          <button :if={@failed_count > 0}
                  phx-click="retry_all_failed"
                  data-confirm={"Retry all #{@failed_count} failed message(s)?"}
                  class="btn btn-warning btn-sm">
            <.icon name="hero-arrow-path" class="w-4 h-4" /> Retry All Failed ({@failed_count})
          </button>
          <div class="flex gap-1">
            <button :for={s <- ["all", "pending", "processed", "failed", "retried"]}
                    phx-click="filter" phx-value-status={s}
                    class={"btn btn-sm #{if @filter_status == s, do: "btn-primary", else: "btn-ghost"}"}>
              {String.capitalize(s)}
            </button>
          </div>
        </div>
      </div>

      <%!-- Search bar --%>
      <form phx-submit="search" class="flex gap-2 flex-wrap">
        <input type="text" name="type" value={@search_type}
               placeholder="Message type (e.g. ADT^A01)"
               class="input input-bordered input-sm flex-1 min-w-32 font-mono" />
        <input type="text" name="patient" value={@search_patient}
               placeholder="Patient ID"
               class="input input-bordered input-sm flex-1 min-w-32 font-mono" />
        <button type="submit" class="btn btn-ghost btn-sm">
          <.icon name="hero-magnifying-glass" class="w-4 h-4" /> Search
        </button>
        <button :if={@search_type != "" or @search_patient != ""}
                type="button"
                phx-click="search" phx-value-type="" phx-value-patient=""
                class="btn btn-ghost btn-sm text-base-content/50">Clear</button>
      </form>

      <div class={"flex gap-4 #{if @selected_entry, do: "items-start", else: ""}"}>
        <%!-- Message table --%>
        <div class={"card bg-base-100 border border-base-300 overflow-hidden flex-1 min-w-0 #{if @selected_entry, do: "w-1/2", else: "w-full"}"}>
          <div class="overflow-x-auto">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>Time</th>
                  <th>Control ID</th>
                  <th>Status</th>
                  <th>Type</th>
                  <th>Patient ID</th>
                  <th>Preview</th>
                </tr>
              </thead>
              <tbody id="entries" phx-update="stream">
                <tr :for={{dom_id, entry} <- @streams.entries}
                    id={dom_id}
                    phx-click="select_entry"
                    phx-value-id={entry.id}
                    class={"cursor-pointer hover #{if @selected_entry && @selected_entry.id == entry.id, do: "bg-primary/10", else: ""}"}>
                  <td class="text-xs text-base-content/60 whitespace-nowrap">
                    {format_dt(entry.inserted_at)}
                  </td>
                  <td class="font-mono text-xs">{entry.message_control_id || "—"}</td>
                  <td><span class={"badge badge-xs #{status_class(entry.status)}"}>{entry.status}</span></td>
                  <td class="text-xs font-mono">{entry.message_type || extract_type(entry.raw_hl7)}</td>
                  <td class="text-xs font-mono">{entry.patient_id || "—"}</td>
                  <td class="text-xs text-base-content/60 max-w-xs truncate font-mono">
                    {String.slice(entry.raw_hl7 || "", 0, 60)}
                  </td>
                </tr>
              </tbody>
            </table>
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
                <span class="text-base-content/50">Status</span>
                <span class={"badge badge-xs #{status_class(@selected_entry.status)}"}>{@selected_entry.status}</span>
              </div>
              <div class="flex justify-between">
                <span class="text-base-content/50">Control ID</span>
                <span class="font-mono">{@selected_entry.message_control_id || "—"}</span>
              </div>
              <div :if={@selected_entry.message_type} class="flex justify-between">
                <span class="text-base-content/50">Type</span>
                <span class="font-mono">{@selected_entry.message_type}</span>
              </div>
              <div :if={@selected_entry.patient_id} class="flex justify-between">
                <span class="text-base-content/50">Patient ID</span>
                <span class="font-mono">{@selected_entry.patient_id}</span>
              </div>
              <div class="flex justify-between">
                <span class="text-base-content/50">Received</span>
                <span>{format_dt(@selected_entry.inserted_at)}</span>
              </div>
              <div :if={@selected_entry.processed_at} class="flex justify-between">
                <span class="text-base-content/50">Processed</span>
                <span>{format_dt(@selected_entry.processed_at)}</span>
              </div>
            </div>

            <button
              :if={@selected_entry.status in ["failed", "processed"]}
              phx-click="retry"
              phx-value-id={@selected_entry.id}
              class="btn btn-sm btn-warning w-full"
            >
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

            <div :if={@selected_entry.transformed_hl7}>
              <p class="text-xs font-semibold text-base-content/50 mb-1">Transformed</p>
              <pre class="text-xs font-mono bg-base-200 rounded p-2 overflow-auto max-h-48 whitespace-pre-wrap">{@selected_entry.transformed_hl7}</pre>
            </div>
          </div>
        </div>
      </div>
    </div>
    </Layouts.app>
    """
  end

  defp load_entries(channel_id, status, message_type, patient_id) do
    opts =
      [limit: 100]
      |> then(fn o -> if status != "all", do: [{:status, status} | o], else: o end)
      |> then(fn o -> if message_type != "", do: [{:message_type, message_type} | o], else: o end)
      |> then(fn o -> if patient_id != "", do: [{:patient_id, patient_id} | o], else: o end)

    Joy.MessageLog.list_recent(channel_id, opts)
  end

  defp count_failed(channel_id) do
    import Ecto.Query
    Joy.Repo.one(
      from e in Joy.MessageLog.Entry,
      where: e.channel_id == ^channel_id and e.status == "failed",
      select: count(e.id)
    ) || 0
  end

  defp format_dt(nil), do: "—"
  defp format_dt(%DateTime{} = dt), do: Calendar.strftime(dt, "%m/%d %H:%M:%S")
  defp format_dt(_), do: "—"

  defp status_class("processed"), do: "badge-success"
  defp status_class("failed"), do: "badge-error"
  defp status_class("pending"), do: "badge-warning"
  defp status_class("retried"), do: "badge-info"
  defp status_class(_), do: "badge-ghost"

  defp extract_type(nil), do: "—"
  defp extract_type(raw) do
    case String.split(raw, "|") do
      [_msh | fields] -> Enum.at(fields, 7, "—")
      _ -> "—"
    end
  end
end
