defmodule JoyWeb.ServiceAccountsLive do
  @moduledoc "Admin-only service account management: create, rotate token, delete."
  use JoyWeb, :live_view

  on_mount {JoyWeb.AdminAuth, :default}

  alias Joy.ServiceAccounts

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Service Accounts")
     |> assign(:service_accounts, ServiceAccounts.list_service_accounts())
     |> assign(:new_name, "")
     |> assign(:revealed_token, nil)}
  end

  @impl true
  def handle_event("create", %{"name" => name}, socket) do
    case ServiceAccounts.create_service_account(name) do
      {:ok, {plain, _sa}} ->
        {:noreply,
         socket
         |> assign(:revealed_token, plain)
         |> assign(:service_accounts, ServiceAccounts.list_service_accounts())
         |> assign(:new_name, "")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to create service account.")}
    end
  end

  def handle_event("rotate", %{"id" => id}, socket) do
    sa = Enum.find(socket.assigns.service_accounts, &(to_string(&1.id) == id))

    case ServiceAccounts.rotate_token(sa) do
      {:ok, plain} ->
        {:noreply,
         socket
         |> assign(:revealed_token, plain)
         |> assign(:service_accounts, ServiceAccounts.list_service_accounts())}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to rotate token.")}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    case ServiceAccounts.delete_service_account(String.to_integer(id)) do
      {:ok, _} ->
        {:noreply, assign(socket, :service_accounts, ServiceAccounts.list_service_accounts())}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Service account not found.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} page_title={@page_title} current_scope={@current_scope}>
      <div class="space-y-6 max-w-3xl">
        <div>
          <h1 class="text-xl font-semibold">Service Accounts</h1>
          <p class="text-sm text-base-content/60 mt-1">
            Machine-actor tokens (<code class="font-mono">joy_svc_</code> prefix) for Prometheus scrapers,
            CI pipelines, and other non-human API clients. Tokens do not expire; rotate them manually.
          </p>
        </div>

        <div :if={@revealed_token} class="alert alert-success">
          <.icon name="hero-key" class="w-5 h-5 shrink-0" />
          <div>
            <p class="font-medium">Token created — copy it now. It will not be shown again.</p>
            <code class="font-mono text-sm break-all select-all">{@revealed_token}</code>
          </div>
        </div>

        <div class="card bg-base-100 border border-base-300 overflow-hidden">
          <div :if={@service_accounts == []} class="p-6 text-sm text-base-content/40">
            No service accounts yet.
          </div>
          <div :if={@service_accounts != []} class="overflow-x-auto">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>Name</th>
                  <th>Created</th>
                  <th>Last used</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                <tr :for={sa <- @service_accounts} class="hover">
                  <td class="font-medium">{sa.name}</td>
                  <td class="text-xs text-base-content/60">
                    {Calendar.strftime(sa.inserted_at, "%Y-%m-%d")}
                  </td>
                  <td class="text-xs text-base-content/60">
                    {if sa.token && sa.token.last_used_at,
                      do: Calendar.strftime(sa.token.last_used_at, "%Y-%m-%d %H:%M UTC"),
                      else: "Never"}
                  </td>
                  <td class="text-right space-x-1">
                    <button
                      phx-click="rotate"
                      phx-value-id={sa.id}
                      data-confirm="Rotate token? The current token will stop working immediately."
                      class="btn btn-ghost btn-xs"
                    >
                      Rotate token
                    </button>
                    <button
                      phx-click="delete"
                      phx-value-id={sa.id}
                      data-confirm="Delete this service account? Its token will stop working immediately."
                      class="btn btn-ghost btn-xs text-error"
                    >
                      Delete
                    </button>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>

        <form phx-submit="create" class="flex gap-2 items-end">
          <div class="form-control flex-1 max-w-xs">
            <label class="label py-1">
              <span class="label-text text-sm">Name</span>
            </label>
            <input
              type="text"
              name="name"
              required
              placeholder="e.g. prometheus-scraper"
              value={@new_name}
              class="input input-bordered input-sm"
            />
          </div>
          <button type="submit" class="btn btn-primary btn-sm">Create</button>
        </form>
      </div>
    </Layouts.app>
    """
  end
end
