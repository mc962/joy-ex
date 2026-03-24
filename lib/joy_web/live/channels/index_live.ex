defmodule JoyWeb.Channels.IndexLive do
  @moduledoc "Channel list with inline new/edit modal."
  use JoyWeb, :live_view
  alias Joy.{Channels, Organizations}
  alias Joy.Channels.Channel

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Joy.PubSub, "channels")
    channels = Channels.list_channels()

    {:ok,
     socket
     |> assign(:page_title, "Channels")
     |> assign(:channels, channels)
     |> assign(:running_ids, running_ids(channels))
     |> assign(:organizations, Organizations.list_organizations())
     |> assign(:show_modal, false)
     |> assign(:form, nil)
     |> assign(:editing_channel, nil)}
  end

  @impl true
  def handle_params(_params, _uri, %{assigns: %{live_action: :new}} = socket) do
    cs = Channel.changeset(%Channel{}, %{})
    {:noreply, assign(socket, show_modal: true, form: to_form(cs), editing_channel: nil)}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_event("new_channel", _, socket) do
    if admin?(socket) do
      cs = Channel.changeset(%Channel{}, %{})
      {:noreply, assign(socket, show_modal: true, form: to_form(cs), editing_channel: nil)}
    else
      {:noreply, put_flash(socket, :error, "Admin access required.")}
    end
  end

  def handle_event("edit_channel", %{"id" => id}, socket) do
    channel = Channels.get_channel!(String.to_integer(id))
    cs = Channel.changeset(channel, %{})
    {:noreply, assign(socket, show_modal: true, form: to_form(cs), editing_channel: channel)}
  end

  def handle_event("close_modal", _, socket) do
    {:noreply, assign(socket, show_modal: false, form: nil)}
  end

  def handle_event("validate", %{"channel" => params}, socket) do
    channel = socket.assigns.editing_channel || %Channel{}
    cs = Channel.changeset(channel, params) |> Map.put(:action, :validate)
    {:noreply, assign(socket, :form, to_form(cs))}
  end

  def handle_event("save", %{"channel" => params}, socket) do
    if admin?(socket) do
      result =
        case socket.assigns.editing_channel do
          nil -> Channels.create_channel(params)
          ch  -> Channels.update_channel(ch, params)
        end

      case result do
        {:ok, ch} ->
          old = socket.assigns.editing_channel
          {action, changes} =
            if old do
              diff = Enum.reduce([:name, :description, :mllp_port, :organization_id], %{}, fn field, acc ->
                if Map.get(old, field) != Map.get(ch, field), do: Map.put(acc, field, Map.get(ch, field)), else: acc
              end)
              {"channel.updated", diff}
            else
              {"channel.created", %{name: ch.name, mllp_port: ch.mllp_port}}
            end
          Joy.AuditLog.log(socket.assigns.current_scope.user, action, "channel", ch.id, ch.name, changes)
          channels = Channels.list_channels()
          {:noreply,
           socket
           |> assign(:show_modal, false)
           |> assign(:channels, channels)
           |> assign(:running_ids, running_ids(channels))
           |> put_flash(:info, "Channel saved")}

        {:error, cs} ->
          {:noreply, assign(socket, :form, to_form(cs))}
      end
    else
      {:noreply, put_flash(socket, :error, "Admin access required.")}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    if admin?(socket) do
      channel = Channels.get_channel!(String.to_integer(id))
      if Joy.ChannelManager.channel_running?(channel.id), do: Joy.ChannelManager.stop_channel(channel.id)
      Channels.delete_channel(channel)
      Joy.AuditLog.log(socket.assigns.current_scope.user, "channel.deleted", "channel", channel.id, channel.name)
      channels = Channels.list_channels()
      {:noreply, assign(socket, channels: channels, running_ids: running_ids(channels))}
    else
      {:noreply, put_flash(socket, :error, "Admin access required.")}
    end
  end

  def handle_event("start_channel", %{"id" => id}, socket) do
    if admin?(socket) do
      channel = Channels.get_channel!(String.to_integer(id))
      Joy.ChannelManager.start_channel(channel)
      Channels.set_started(channel, true)
      Joy.AuditLog.log(socket.assigns.current_scope.user, "channel.started", "channel", channel.id, channel.name)
      {:noreply, assign(socket, :running_ids, MapSet.put(socket.assigns.running_ids, channel.id))}
    else
      {:noreply, put_flash(socket, :error, "Admin access required.")}
    end
  end

  def handle_event("stop_channel", %{"id" => id}, socket) do
    if admin?(socket) do
      id = String.to_integer(id)
      channel = Channels.get_channel!(id)
      Joy.ChannelManager.stop_channel(id)
      Channels.set_started(channel, false)
      Joy.AuditLog.log(socket.assigns.current_scope.user, "channel.stopped", "channel", channel.id, channel.name)
      {:noreply, assign(socket, :running_ids, MapSet.delete(socket.assigns.running_ids, channel.id))}
    else
      {:noreply, put_flash(socket, :error, "Admin access required.")}
    end
  end

  @impl true
  # Structural changes (create/delete) need a full refresh including running_ids.
  def handle_info({event, _}, socket) when event in [:channel_created, :channel_deleted] do
    channels = Channels.list_channels()
    {:noreply, assign(socket, channels: channels, running_ids: running_ids(channels))}
  end

  # Config updates refresh channel data but must not overwrite the optimistic running_ids
  # set by start_channel/stop_channel — channel_running? may not reflect reality yet.
  def handle_info({:channel_updated, _}, socket) do
    {:noreply, assign(socket, :channels, Channels.list_channels())}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} page_title={@page_title} current_scope={@current_scope}>
    <div class="space-y-4">
      <div class="flex items-center justify-between">
        <p class="text-sm text-base-content/60">
          {length(@channels)} channel{if length(@channels) != 1, do: "s", else: ""} configured
        </p>
        <button :if={@current_scope.user.is_admin} phx-click="new_channel" class="btn btn-primary btn-sm">
          <.icon name="hero-plus" class="w-4 h-4" /> New Channel
        </button>
      </div>

      <div class="card bg-base-100 border border-base-300 overflow-hidden">
        <div :if={@channels == []} class="flex flex-col items-center py-16 text-base-content/40">
          <.icon name="hero-arrows-right-left" class="w-10 h-10 mb-3" />
          <p class="font-medium">No channels yet</p>
          <p class="text-sm mt-1">Create a channel to start receiving HL7 messages</p>
        </div>
        <div :if={@channels != []} class="overflow-x-auto">
          <table class="table">
            <thead>
              <tr>
                <th>Name</th>
                <th>Org</th>
                <th>Port</th>
                <th>Status</th>
                <th>Transforms</th>
                <th>Destinations</th>
                <th class="text-right">Actions</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={ch <- @channels} class="hover">
                <td>
                  <div>
                    <p class="font-medium">{ch.name}</p>
                    <p :if={ch.description} class="text-xs text-base-content/50">{ch.description}</p>
                  </div>
                </td>
                <td>
                  <span :if={ch.organization} class="badge badge-outline badge-sm">{ch.organization.name}</span>
                  <span :if={!ch.organization} class="text-base-content/30 text-sm">—</span>
                </td>
                <td><span class="font-mono text-sm">{ch.mllp_port}</span></td>
                <td>
                  <span :if={ch.id in @running_ids} class="badge badge-success badge-sm">Running</span>
                  <span :if={ch.id not in @running_ids} class="badge badge-ghost badge-sm">Stopped</span>
                </td>
                <td class="text-sm text-base-content/60">{length(ch.transform_steps)}</td>
                <td class="text-sm text-base-content/60">{length(ch.destination_configs)}</td>
                <td>
                  <div class="flex items-center justify-end gap-1">
                    <%= if @current_scope.user.is_admin do %>
                      <button :if={ch.id not in @running_ids}
                              phx-click="start_channel" phx-value-id={ch.id}
                              class="btn btn-ghost btn-xs text-success">Start</button>
                      <button :if={ch.id in @running_ids}
                              phx-click="stop_channel" phx-value-id={ch.id}
                              class="btn btn-ghost btn-xs">Stop</button>
                    <% end %>
                    <.link navigate={~p"/channels/#{ch.id}"} class="btn btn-ghost btn-xs">View</.link>
                    <%= if @current_scope.user.is_admin do %>
                      <button phx-click="edit_channel" phx-value-id={ch.id}
                              class="btn btn-ghost btn-xs">Edit</button>
                      <button phx-click="delete" phx-value-id={ch.id}
                              data-confirm={"Delete #{ch.name}?"}
                              class="btn btn-ghost btn-xs text-error">Delete</button>
                    <% end %>
                  </div>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </div>

    <%!-- New/Edit modal --%>
    <div :if={@show_modal} class="modal modal-open">
      <div class="modal-box">
        <h3 class="font-bold text-lg mb-4">
          {if @editing_channel, do: "Edit Channel", else: "New Channel"}
        </h3>
        <.form for={@form} phx-change="validate" phx-submit="save" class="space-y-4">
          <.input field={@form[:name]} label="Name" placeholder="e.g. ADT Feed" />
          <.input field={@form[:description]} label="Description" placeholder="Optional description" />
          <.input field={@form[:mllp_port]} type="number" label="MLLP Port" placeholder="e.g. 2575" />
          <div>
            <label class="label"><span class="label-text">Organization (optional)</span></label>
            <select name="channel[organization_id]" class="select select-bordered w-full">
              <option value="">— None —</option>
              <option :for={org <- @organizations}
                      value={org.id}
                      selected={to_string(Phoenix.HTML.Form.input_value(@form, :organization_id)) == to_string(org.id)}>
                {org.name}
              </option>
            </select>
          </div>
          <div class="modal-action">
            <button type="button" phx-click="close_modal" class="btn btn-ghost">Cancel</button>
            <button type="submit" class="btn btn-primary">Save</button>
          </div>
        </.form>
      </div>
      <div class="modal-backdrop" phx-click="close_modal"></div>
    </div>
    </Layouts.app>
    """
  end

  defp running_ids(channels) do
    channels
    |> Enum.filter(&Joy.ChannelManager.channel_running?(&1.id))
    |> MapSet.new(& &1.id)
  end
end
