defmodule JoyWeb.UserSettingsController do
  use JoyWeb, :controller

  alias Joy.Accounts
  alias JoyWeb.UserAuth

  import JoyWeb.UserAuth, only: [require_sudo_mode: 2]

  plug :require_sudo_mode
  plug :assign_email_and_password_changesets

  def edit(conn, _params) do
    render(conn, :edit)
  end

  def update(conn, %{"action" => "update_email"} = params) do
    %{"user" => user_params} = params
    user = conn.assigns.current_scope.user

    case Accounts.change_user_email(user, user_params) do
      %{valid?: true} = changeset ->
        Accounts.deliver_user_update_email_instructions(
          Ecto.Changeset.apply_action!(changeset, :insert),
          user.email,
          &url(~p"/users/settings/confirm-email/#{&1}")
        )

        conn
        |> put_flash(
          :info,
          "A link to confirm your email change has been sent to the new address."
        )
        |> redirect(to: ~p"/users/settings")

      changeset ->
        render(conn, :edit, email_changeset: %{changeset | action: :insert})
    end
  end

  def update(conn, %{"action" => "update_password"} = params) do
    %{"user" => user_params} = params
    user = conn.assigns.current_scope.user

    case Accounts.update_user_password(user, user_params) do
      {:ok, {user, _}} ->
        conn
        |> put_flash(:info, "Password updated successfully.")
        |> put_session(:user_return_to, ~p"/users/settings")
        |> UserAuth.log_in_user(user)

      {:error, changeset} ->
        render(conn, :edit, password_changeset: changeset)
    end
  end

  def confirm_email(conn, %{"token" => token}) do
    case Accounts.update_user_email(conn.assigns.current_scope.user, token) do
      {:ok, _user} ->
        conn
        |> put_flash(:info, "Email changed successfully.")
        |> redirect(to: ~p"/users/settings")

      {:error, _} ->
        conn
        |> put_flash(:error, "Email change link is invalid or it has expired.")
        |> redirect(to: ~p"/users/settings")
    end
  end

  def create_token(conn, %{"token" => %{"name" => name}}) do
    user = conn.assigns.current_scope.user

    case Joy.ApiTokens.create_token(user, %{"name" => name}) do
      {:ok, {plain, _token}} ->
        conn
        |> put_flash(:token_created, plain)
        |> redirect(to: ~p"/users/settings")

      {:error, :token_limit_reached} ->
        conn
        |> put_flash(:error, "Token limit reached (10 max). Revoke an existing token first.")
        |> redirect(to: ~p"/users/settings")
    end
  end

  def revoke_token(conn, %{"id" => id}) do
    Joy.ApiTokens.revoke_token(conn.assigns.current_scope.user, id)

    conn
    |> put_flash(:info, "API token revoked.")
    |> redirect(to: ~p"/users/settings")
  end

  defp assign_email_and_password_changesets(conn, _opts) do
    user = conn.assigns.current_scope.user

    conn
    |> assign(:email_changeset, Accounts.change_user_email(user))
    |> assign(:password_changeset, Accounts.change_user_password(user))
    |> assign(:api_tokens, Joy.ApiTokens.list_tokens(user))
  end
end
