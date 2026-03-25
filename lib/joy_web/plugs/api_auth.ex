defmodule JoyWeb.Plugs.ApiAuth do
  @moduledoc "Authenticates API requests via Bearer token in the Authorization header."

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  alias Joy.Accounts.Scope

  def init(opts), do: opts

  def call(conn, _opts) do
    with ["Bearer " <> plain] <- get_req_header(conn, "authorization"),
         {:ok, token_id, scope} <- authenticate(plain) do
      Task.start(fn -> touch_last_used(plain, token_id) end)
      conn
      |> assign(:current_scope, scope)
      |> assign(:api_token_id, token_id)
    else
      _ ->
        conn
        |> put_status(:unauthorized)
        |> json(%{errors: %{detail: "Invalid or missing API token"}})
        |> halt()
    end
  end

  defp authenticate("joy_svc_" <> _ = plain) do
    case Joy.ServiceAccounts.verify_token(plain) do
      {:ok, token_id, sa} -> {:ok, token_id, Scope.for_service_account(sa)}
      err -> err
    end
  end

  defp authenticate(plain) do
    case Joy.ApiTokens.verify_token(plain) do
      {:ok, token_id, user} -> {:ok, token_id, Scope.for_user(user)}
      err -> err
    end
  end

  defp touch_last_used("joy_svc_" <> _, token_id), do: Joy.ServiceAccounts.touch_last_used(token_id)
  defp touch_last_used(_, token_id), do: Joy.ApiTokens.touch_last_used(token_id)
end
