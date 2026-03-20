defmodule JoyWeb.Tools.SinksLive do
  @moduledoc "Real-time message sink inspector for testing destinations."
  use JoyWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Joy.PubSub, "sinks")
    end

    sinks = Joy.Sinks.all()

    {:ok,
     socket
     |> assign(:page_title, "Message Sinks")
     |> assign(:sinks, sinks)
     |> assign(:selected, sinks |> Map.keys() |> Enum.sort() |> List.first())
     |> assign(:expanded, MapSet.new())}
  end

  @impl true
  def handle_event("select_sink", %{"name" => name}, socket) do
    {:noreply, assign(socket, :selected, name)}
  end

  def handle_event("clear_sink", %{"name" => name}, socket) do
    Joy.Sinks.clear(name)
    {:noreply, socket}
  end

  def handle_event("toggle_entry", %{"id" => id}, socket) do
    id = String.to_integer(id)
    expanded =
      if MapSet.member?(socket.assigns.expanded, id) do
        MapSet.delete(socket.assigns.expanded, id)
      else
        MapSet.put(socket.assigns.expanded, id)
      end

    {:noreply, assign(socket, :expanded, expanded)}
  end

  @impl true
  def handle_info({:sink_message, name, entry}, socket) do
    sinks = Map.update(socket.assigns.sinks, name, [entry], &[entry | &1])
    selected = socket.assigns.selected || name
    {:noreply, assign(socket, sinks: sinks, selected: selected)}
  end

  def handle_info({:sink_cleared, name}, socket) do
    sinks = Map.put(socket.assigns.sinks, name, [])
    {:noreply, assign(socket, :sinks, sinks)}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} page_title={@page_title} current_scope={@current_scope}>
    <div class="flex gap-6 h-full" style="min-height: 600px">

      <%!-- Left: sink list --%>
      <div class="w-56 shrink-0 space-y-1">
        <p class="text-xs font-semibold uppercase tracking-wider text-base-content/40 px-2 mb-3">
          Sinks
        </p>

        <div :if={map_size(@sinks) == 0}
             class="text-xs text-base-content/40 italic px-2 py-4">
          No messages yet. Configure a <span class="font-mono">sink</span> destination on a channel to start capturing.
        </div>

        <button
          :for={name <- @sinks |> Map.keys() |> Enum.sort()}
          phx-click="select_sink"
          phx-value-name={name}
          class={"w-full flex items-center justify-between px-3 py-2 rounded-lg text-sm transition-colors
                  #{if @selected == name, do: "bg-primary text-primary-content", else: "hover:bg-base-200 text-base-content/70"}"}
        >
          <span class="font-mono truncate">{name}</span>
          <span class={"badge badge-sm #{if @selected == name, do: "badge-primary-content bg-primary-content/20 text-primary-content", else: "badge-ghost"}"}>
            {length(Map.get(@sinks, name, []))}
          </span>
        </button>
      </div>

      <%!-- Right: message list --%>
      <div class="flex-1 min-w-0">
        <div :if={is_nil(@selected) or map_size(@sinks) == 0}
             class="flex flex-col items-center justify-center h-64 text-base-content/30">
          <.icon name="hero-inbox" class="w-10 h-10 mb-3" />
          <p class="text-sm">Select a sink to inspect messages</p>
        </div>

        <div :if={@selected && Map.has_key?(@sinks, @selected)}>
          <div class="flex items-center justify-between mb-4">
            <h2 class="font-semibold font-mono">{@selected}</h2>
            <button
              phx-click="clear_sink"
              phx-value-name={@selected}
              data-confirm={"Clear all messages from '#{@selected}'?"}
              class="btn btn-ghost btn-xs text-error"
            >
              <.icon name="hero-trash" class="w-3.5 h-3.5" /> Clear
            </button>
          </div>

          <div :if={Map.get(@sinks, @selected, []) == []}
               class="text-sm text-base-content/40 text-center py-12">
            No messages yet.
          </div>

          <div class="space-y-2">
            <div
              :for={entry <- Map.get(@sinks, @selected, [])}
              class="card bg-base-100 border border-base-300 overflow-hidden"
            >
              <%!-- Summary row (always visible) --%>
              <button
                class="w-full flex items-center gap-4 px-4 py-3 text-left hover:bg-base-200/50 transition-colors"
                phx-click="toggle_entry"
                phx-value-id={entry.id}
              >
                <span class="badge badge-outline badge-sm font-mono shrink-0">
                  {entry.msg_type}
                </span>
                <span class="text-xs font-mono text-base-content/60 shrink-0">
                  {entry.control_id}
                </span>
                <span class="text-xs text-base-content/40 shrink-0">
                  from {entry.sending_app}
                </span>
                <span class="flex-1" />
                <span class="text-xs text-base-content/40 shrink-0">
                  {format_dt(entry.received_at)}
                </span>
                <.icon
                  name={if MapSet.member?(@expanded, entry.id), do: "hero-chevron-up", else: "hero-chevron-down"}
                  class="w-3.5 h-3.5 text-base-content/30 shrink-0"
                />
              </button>

              <%!-- Expanded raw HL7 --%>
              <div :if={MapSet.member?(@expanded, entry.id)}
                   class="border-t border-base-300 px-4 py-3 bg-base-200/40">
                <pre class="text-xs font-mono whitespace-pre-wrap break-all text-base-content/80">{format_hl7(entry.raw)}</pre>
              </div>
            </div>
          </div>
        </div>
      </div>

    </div>
    </Layouts.app>
    """
  end

  defp format_dt(%DateTime{} = dt), do: Calendar.strftime(dt, "%H:%M:%S.%f" |> String.slice(0, 12))
  defp format_dt(_), do: "—"

  # Replace \r segment separators with newlines for readable display
  defp format_hl7(raw), do: String.replace(raw, "\r", "\n")
end
