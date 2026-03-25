defmodule JoyWeb.Organizations.IndexLive do
  @moduledoc "Organization list with inline new/edit modal."
  use JoyWeb, :live_view
  alias Joy.Organizations
  alias Joy.Organizations.Organization

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Joy.PubSub, "organizations")
    orgs = Organizations.list_organizations(socket.assigns.current_scope)

    {:ok,
     socket
     |> assign(:page_title, "Organizations")
     |> assign(:organizations, orgs)
     |> assign(:show_modal, false)
     |> assign(:form, nil)
     |> assign(:editing_org, nil)}
  end

  @impl true
  def handle_params(_params, _uri, %{assigns: %{live_action: :new}} = socket) do
    cs = Organization.changeset(%Organization{}, %{})
    {:noreply, assign(socket, show_modal: true, form: to_form(cs), editing_org: nil)}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_event("new_org", _, socket) do
    if admin?(socket) do
      cs = Organization.changeset(%Organization{}, %{})
      {:noreply, assign(socket, show_modal: true, form: to_form(cs), editing_org: nil)}
    else
      {:noreply, put_flash(socket, :error, "Admin access required.")}
    end
  end

  def handle_event("close_modal", _, socket) do
    {:noreply, assign(socket, show_modal: false, form: nil)}
  end

  def handle_event("validate", %{"organization" => params}, socket) do
    org = socket.assigns.editing_org || %Organization{}
    cs = Organization.changeset(org, params) |> Map.put(:action, :validate)
    {:noreply, assign(socket, :form, to_form(cs))}
  end

  def handle_event("save", %{"organization" => params}, socket) do
    if admin?(socket) do
      result =
        case socket.assigns.editing_org do
          nil -> Organizations.create_organization(params)
          org -> Organizations.update_organization(org, params)
        end

      case result do
        {:ok, org} ->
          action = if socket.assigns.editing_org, do: "organization.updated", else: "organization.created"
          Joy.AuditLog.log(socket.assigns.current_scope.user, action, "organization", org.id, org.name)
          {:noreply,
           socket
           |> assign(:show_modal, false)
           |> assign(:organizations, Organizations.list_organizations(socket.assigns.current_scope))
           |> put_flash(:info, "Organization saved")
           |> push_navigate(to: ~p"/organizations/#{org.id}")}

        {:error, cs} ->
          {:noreply, assign(socket, :form, to_form(cs))}
      end
    else
      {:noreply, put_flash(socket, :error, "Admin access required.")}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    if admin?(socket) do
      org = Organizations.get_organization!(String.to_integer(id))
      {:ok, _} = Organizations.delete_organization(org)
      Joy.AuditLog.log(socket.assigns.current_scope.user, "organization.deleted", "organization", org.id, org.name)
      {:noreply, assign(socket, :organizations, Organizations.list_organizations(socket.assigns.current_scope))}
    else
      {:noreply, put_flash(socket, :error, "Admin access required.")}
    end
  end

  @impl true
  def handle_info({event, _}, socket) when event in [:org_created, :org_deleted, :org_updated] do
    {:noreply, assign(socket, :organizations, Organizations.list_organizations(socket.assigns.current_scope))}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} page_title={@page_title} current_scope={@current_scope}>
    <div class="space-y-4">
      <div class="flex items-center justify-between">
        <p class="text-sm text-base-content/60">
          {length(@organizations)} organization{if length(@organizations) != 1, do: "s", else: ""} configured
        </p>
        <button :if={@current_scope.user.is_admin} phx-click="new_org" class="btn btn-primary btn-sm">
          <.icon name="hero-plus" class="w-4 h-4" /> New Organization
        </button>
      </div>

      <div class="card bg-base-100 border border-base-300 overflow-hidden">
        <div :if={@organizations == []} class="flex flex-col items-center py-16 text-base-content/40">
          <.icon name="hero-building-office-2" class="w-10 h-10 mb-3" />
          <p class="font-medium">No organizations yet</p>
          <p class="text-sm mt-1">Create an organization to group channels by health system</p>
        </div>
        <div :if={@organizations != []} class="overflow-x-auto">
          <table class="table">
            <thead>
              <tr>
                <th>Name</th>
                <th>Slug</th>
                <th>Channels</th>
                <th class="text-right">Actions</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={org <- @organizations} class="hover">
                <td>
                  <div>
                    <p class="font-medium">{org.name}</p>
                    <p :if={org.description} class="text-xs text-base-content/50">{org.description}</p>
                  </div>
                </td>
                <td><span class="font-mono text-sm">{org.slug}</span></td>
                <td class="text-sm text-base-content/60">
                  {if Ecto.assoc_loaded?(org.channels), do: length(org.channels), else: "—"}
                </td>
                <td>
                  <div class="flex items-center justify-end gap-1">
                    <.link navigate={~p"/organizations/#{org.id}"} class="btn btn-ghost btn-xs">View</.link>
                    <button :if={@current_scope.user.is_admin}
                            phx-click="delete" phx-value-id={org.id}
                            data-confirm={"Delete #{org.name}? Channels will be ungrouped."}
                            class="btn btn-ghost btn-xs text-error">Delete</button>
                  </div>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </div>

    <%!-- New Organization modal --%>
    <div :if={@show_modal} class="modal modal-open">
      <div class="modal-box">
        <h3 class="font-bold text-lg mb-4">New Organization</h3>
        <.form for={@form} phx-change="validate" phx-submit="save" class="space-y-4">
          <.input field={@form[:name]} label="Name" placeholder="e.g. National Children's Hospital" />
          <.input field={@form[:slug]} label="Slug" placeholder="auto-generated from name" />
          <.input field={@form[:description]} label="Description" placeholder="Optional description" />
          <.input field={@form[:alert_email]} label="Alert Email" placeholder="alerts@example.com" />
          <.input field={@form[:alert_webhook_url]} label="Alert Webhook URL" placeholder="https://..." />
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
end
