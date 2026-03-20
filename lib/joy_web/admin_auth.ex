defmodule JoyWeb.AdminAuth do
  @moduledoc """
  LiveView on_mount hook that enforces admin-only access.

  Applied after UserAuth.on_mount(:require_authenticated), so `current_scope`
  is guaranteed to be present. Redirects non-admin users to "/" with a flash.

  To grant admin: set `is_admin: true` on the User record directly in the DB
  or via a mix task. No self-service promotion is intentionally provided.
  """

  import Phoenix.LiveView
  use JoyWeb, :verified_routes

  def on_mount(:default, _params, _session, socket) do
    user = socket.assigns[:current_scope] && socket.assigns.current_scope.user

    if user && user.is_admin do
      {:cont, socket}
    else
      socket =
        socket
        |> put_flash(:error, "You are not authorized to access this page.")
        |> redirect(to: ~p"/users/log-in")

      {:halt, socket}
    end
  end
end
