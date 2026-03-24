defmodule JoyWeb.Organizations.ShowLive do
  @moduledoc "Organization detail page: general info, member channels, IP allowlist, alert config, TLS CA cert."
  use JoyWeb, :live_view
  alias Joy.Organizations
  alias Joy.Organizations.Organization

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    org = Organizations.get_organization!(String.to_integer(id)) |> Joy.Repo.preload(:channels)

    if connected?(socket), do: Phoenix.PubSub.subscribe(Joy.PubSub, "organizations")

    {:ok,
     socket
     |> assign(:page_title, org.name)
     |> assign(:org, org)
     |> assign(:general_form, to_form(Organization.changeset(org, %{})))
     |> assign(:alert_form, to_form(Organization.changeset(org, %{})))
     |> assign(:ip_error, nil)
     |> assign(:tls_form, to_form(Organization.changeset(org, %{})))}
  end

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:org_updated, org} = _msg, socket) when org.id == socket.assigns.org.id do
    refreshed = Organizations.get_organization!(org.id) |> Joy.Repo.preload(:channels)
    {:noreply, assign(socket, :org, refreshed)}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  # --- General section ---

  @impl true
  def handle_event("validate_general", %{"organization" => params}, socket) do
    cs = Organization.changeset(socket.assigns.org, params) |> Map.put(:action, :validate)
    {:noreply, assign(socket, :general_form, to_form(cs))}
  end

  def handle_event("save_general", %{"organization" => params}, socket) do
    if admin?(socket) do
      case Organizations.update_organization(socket.assigns.org, params) do
        {:ok, org} ->
          Joy.AuditLog.log(socket.assigns.current_scope.user, "organization.updated",
            "organization", org.id, org.name)
          refreshed = Organizations.get_organization!(org.id) |> Joy.Repo.preload(:channels)
          {:noreply,
           socket
           |> assign(:org, refreshed)
           |> assign(:general_form, to_form(Organization.changeset(refreshed, %{})))
           |> put_flash(:info, "Organization updated")}

        {:error, cs} ->
          {:noreply, assign(socket, :general_form, to_form(cs))}
      end
    else
      {:noreply, put_flash(socket, :error, "Admin access required.")}
    end
  end

  # --- IP allowlist section ---

  def handle_event("add_allowed_ip", %{"ip" => raw_ip}, socket) do
    if admin?(socket) do
      ip = String.trim(raw_ip)
      org = socket.assigns.org

      case Organizations.update_organization(org, %{allowed_ips: org.allowed_ips ++ [ip]}) do
        {:ok, updated} ->
          Joy.AuditLog.log(socket.assigns.current_scope.user, "organization.ip_added",
            "organization", org.id, org.name, %{ip: ip})
          refreshed = Organizations.get_organization!(updated.id) |> Joy.Repo.preload(:channels)
          {:noreply, assign(socket, org: refreshed, ip_error: nil)}

        {:error, cs} ->
          msg = cs.errors[:allowed_ips] |> then(fn {m, _} -> m end)
          {:noreply, assign(socket, :ip_error, msg)}
      end
    else
      {:noreply, put_flash(socket, :error, "Admin access required.")}
    end
  end

  def handle_event("remove_allowed_ip", %{"ip" => ip}, socket) do
    if admin?(socket) do
      org = socket.assigns.org
      new_ips = Enum.reject(org.allowed_ips, &(&1 == ip))

      case Organizations.update_organization(org, %{allowed_ips: new_ips}) do
        {:ok, updated} ->
          Joy.AuditLog.log(socket.assigns.current_scope.user, "organization.ip_removed",
            "organization", org.id, org.name, %{ip: ip})
          refreshed = Organizations.get_organization!(updated.id) |> Joy.Repo.preload(:channels)
          {:noreply, assign(socket, org: refreshed, ip_error: nil)}

        {:error, _} ->
          {:noreply, socket}
      end
    else
      {:noreply, put_flash(socket, :error, "Admin access required.")}
    end
  end

  # --- Alert section ---

  def handle_event("validate_alert", %{"organization" => params}, socket) do
    cs = Organization.changeset(socket.assigns.org, params) |> Map.put(:action, :validate)
    {:noreply, assign(socket, :alert_form, to_form(cs))}
  end

  def handle_event("save_alert", %{"organization" => params}, socket) do
    if admin?(socket) do
      case Organizations.update_organization(socket.assigns.org, params) do
        {:ok, org} ->
          Joy.AuditLog.log(socket.assigns.current_scope.user, "organization.alert_updated",
            "organization", org.id, org.name)
          refreshed = Organizations.get_organization!(org.id) |> Joy.Repo.preload(:channels)
          {:noreply,
           socket
           |> assign(:org, refreshed)
           |> assign(:alert_form, to_form(Organization.changeset(refreshed, %{})))
           |> put_flash(:info, "Alert config saved")}

        {:error, cs} ->
          {:noreply, assign(socket, :alert_form, to_form(cs))}
      end
    else
      {:noreply, put_flash(socket, :error, "Admin access required.")}
    end
  end

  # --- TLS CA cert section ---

  def handle_event("validate_tls", %{"organization" => params}, socket) do
    cs = Organization.changeset(socket.assigns.org, params) |> Map.put(:action, :validate)
    {:noreply, assign(socket, :tls_form, to_form(cs))}
  end

  def handle_event("save_tls", %{"organization" => params}, socket) do
    if admin?(socket) do
      case Organizations.update_organization(socket.assigns.org, params) do
        {:ok, org} ->
          Joy.AuditLog.log(socket.assigns.current_scope.user, "organization.tls_updated",
            "organization", org.id, org.name,
            %{ca_cert_updated: params["tls_ca_cert_pem"] not in [nil, ""]})
          refreshed = Organizations.get_organization!(org.id) |> Joy.Repo.preload(:channels)
          {:noreply,
           socket
           |> assign(:org, refreshed)
           |> assign(:tls_form, to_form(Organization.changeset(refreshed, %{})))
           |> put_flash(:info, "TLS CA cert saved")}

        {:error, cs} ->
          {:noreply, assign(socket, :tls_form, to_form(cs))}
      end
    else
      {:noreply, put_flash(socket, :error, "Admin access required.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} page_title={@page_title} current_scope={@current_scope}>
    <div class="space-y-6">

      <%!-- Breadcrumb --%>
      <div class="flex items-center gap-2 text-sm text-base-content/60">
        <.link navigate={~p"/organizations"} class="hover:text-base-content">Organizations</.link>
        <span>/</span>
        <span class="text-base-content font-medium">{@org.name}</span>
      </div>

      <%!-- General (admin only) --%>
      <%= if @current_scope.user.is_admin do %>
      <div class="card bg-base-100 border border-base-300">
        <div class="card-body">
          <h2 class="card-title text-base mb-4">General</h2>
          <.form for={@general_form} phx-change="validate_general" phx-submit="save_general" class="space-y-4">
            <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
              <.input field={@general_form[:name]} label="Name" />
              <.input field={@general_form[:slug]} label="Slug" />
            </div>
            <.input field={@general_form[:description]} label="Description" />
            <div class="card-actions justify-end">
              <button type="submit" class="btn btn-primary btn-sm">Save</button>
            </div>
          </.form>
        </div>
      </div>
      <% end %>

      <%!-- Member Channels --%>
      <div class="card bg-base-100 border border-base-300">
        <div class="card-body">
          <h2 class="card-title text-base mb-4">
            Member Channels
            <span class="badge badge-ghost badge-sm">{length(@org.channels)}</span>
          </h2>
          <div :if={@org.channels == []} class="text-sm text-base-content/50">
            No channels assigned. Edit a channel and set its organization.
          </div>
          <div :if={@org.channels != []} class="overflow-x-auto">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>Name</th>
                  <th>Port</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                <tr :for={ch <- @org.channels} class="hover">
                  <td class="font-medium">{ch.name}</td>
                  <td class="font-mono text-sm">{ch.mllp_port}</td>
                  <td>
                    <.link navigate={~p"/channels/#{ch.id}"} class="btn btn-ghost btn-xs">View</.link>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </div>

      <%!-- IP Allowlist (admin only) --%>
      <%= if @current_scope.user.is_admin do %>
      <div class="card bg-base-100 border border-base-300">
        <div class="card-body">
          <h2 class="card-title text-base mb-1">IP Allowlist</h2>
          <p class="text-sm text-base-content/60 mb-4">
            Org-level IPs are unioned with each member channel's own allowlist.
            Leave empty to apply no org-level restriction.
          </p>

          <div class="flex flex-wrap gap-2 mb-3">
            <div :for={ip <- @org.allowed_ips}
                 class="badge badge-outline gap-2 py-3 px-3">
              <span class="font-mono text-xs">{ip}</span>
              <button phx-click="remove_allowed_ip" phx-value-ip={ip}
                      class="text-error hover:text-error/70 font-bold">×</button>
            </div>
            <div :if={@org.allowed_ips == []} class="text-sm text-base-content/40">
              No IPs configured — no org-level restriction
            </div>
          </div>

          <.form for={%{}} phx-submit="add_allowed_ip" class="flex gap-2">
            <input type="text" name="ip" placeholder="10.0.0.0/24 or 192.168.1.5"
                   class="input input-bordered input-sm flex-1 font-mono text-sm" />
            <button type="submit" class="btn btn-sm btn-outline">Add IP</button>
          </.form>
          <p :if={@ip_error} class="text-error text-xs mt-1">{@ip_error}</p>
        </div>
      </div>

      <%!-- Alert Config (admin only) --%>
      <div class="card bg-base-100 border border-base-300">
        <div class="card-body">
          <h2 class="card-title text-base mb-1">Alert Config</h2>
          <p class="text-sm text-base-content/60 mb-4">
            Fallback alert destinations used when a member channel has no individual alert config.
          </p>
          <.form for={@alert_form} phx-change="validate_alert" phx-submit="save_alert" class="space-y-4">
            <.input field={@alert_form[:alert_email]} label="Alert Email" placeholder="alerts@example.com" />
            <.input field={@alert_form[:alert_webhook_url]} label="Alert Webhook URL" placeholder="https://..." />
            <div class="card-actions justify-end">
              <button type="submit" class="btn btn-primary btn-sm">Save</button>
            </div>
          </.form>
        </div>
      </div>

      <%!-- TLS CA Cert (admin only) --%>
      <div class="card bg-base-100 border border-base-300">
        <div class="card-body">
          <h2 class="card-title text-base mb-1">TLS CA Certificate</h2>
          <p class="text-sm text-base-content/60 mb-4">
            Org-level CA cert used as fallback for member channels with mTLS peer verification enabled but no individual CA cert configured.
          </p>
          <.form for={@tls_form} phx-change="validate_tls" phx-submit="save_tls" class="space-y-4">
            <div>
              <label class="label"><span class="label-text">CA Certificate (PEM)</span></label>
              <textarea name="organization[tls_ca_cert_pem]"
                        class="textarea textarea-bordered w-full font-mono text-xs"
                        rows="8"
                        placeholder="-----BEGIN CERTIFICATE-----&#10;...&#10;-----END CERTIFICATE-----"
              >{Phoenix.HTML.Form.input_value(@tls_form, :tls_ca_cert_pem)}</textarea>
            </div>
            <div class="card-actions justify-end">
              <button type="submit" class="btn btn-primary btn-sm">Save</button>
            </div>
          </.form>
        </div>
      </div>
      <% end %>

    </div>
    </Layouts.app>
    """
  end
end
