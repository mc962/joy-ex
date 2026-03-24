defmodule JoyWeb.Users.IndexLive do
  @moduledoc "Admin-only user management: list users, promote/demote admin."
  use JoyWeb, :live_view

  alias Joy.Accounts

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Users")
     |> assign(:users, Accounts.list_users())}
  end

  @impl true
  def handle_event("promote", %{"id" => id}, socket) do
    user = Accounts.get_user!(String.to_integer(id))
    {:ok, _} = Accounts.set_admin(user, true)
    Joy.AuditLog.log(socket.assigns.current_scope.user, "user.promoted", "user", user.id, user.email)
    {:noreply, assign(socket, :users, Accounts.list_users())}
  end

  def handle_event("demote", %{"id" => id}, socket) do
    user = Accounts.get_user!(String.to_integer(id))

    if user.id == socket.assigns.current_scope.user.id do
      {:noreply, put_flash(socket, :error, "You cannot remove your own admin privileges.")}
    else
      {:ok, _} = Accounts.set_admin(user, false)
      Joy.AuditLog.log(socket.assigns.current_scope.user, "user.demoted", "user", user.id, user.email)
      {:noreply, assign(socket, :users, Accounts.list_users())}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} page_title={@page_title} current_scope={@current_scope}>
    <div class="space-y-4 max-w-3xl">
      <div class="flex items-center justify-between">
        <p class="text-sm text-base-content/60">{length(@users)} registered user(s)</p>
      </div>

      <div class="card bg-base-100 border border-base-300 overflow-hidden">
        <div class="overflow-x-auto">
          <table class="table table-sm">
            <thead>
              <tr>
                <th>Email</th>
                <th>Confirmed</th>
                <th>Admin</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={user <- @users}>
                <td class="font-mono text-sm">{user.email}</td>
                <td>
                  <span :if={user.confirmed_at} class="badge badge-success badge-sm">Yes</span>
                  <span :if={!user.confirmed_at} class="badge badge-ghost badge-sm">No</span>
                </td>
                <td>
                  <span :if={user.is_admin} class="badge badge-warning badge-sm">Admin</span>
                  <span :if={!user.is_admin} class="badge badge-ghost badge-sm">User</span>
                </td>
                <td class="text-right">
                  <button
                    :if={!user.is_admin}
                    phx-click="promote"
                    phx-value-id={user.id}
                    class="btn btn-xs btn-warning"
                  >
                    Make Admin
                  </button>
                  <button
                    :if={user.is_admin && user.id != @current_scope.user.id}
                    phx-click="demote"
                    phx-value-id={user.id}
                    data-confirm="Remove admin privileges from this user?"
                    class="btn btn-xs btn-ghost"
                  >
                    Revoke Admin
                  </button>
                  <span
                    :if={user.is_admin && user.id == @current_scope.user.id}
                    class="text-xs text-base-content/30"
                  >
                    (you)
                  </span>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </div>
    </Layouts.app>
    """
  end
end
