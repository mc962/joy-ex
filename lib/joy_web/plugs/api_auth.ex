defmodule JoyWeb.Plugs.ApiAuth do
  @moduledoc "Authenticates API requests via Bearer token in the Authorization header."

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  def init(opts), do: opts

  def call(conn, _opts) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, token_id, user} <- Joy.ApiTokens.verify_token(token) do
      Task.start(fn -> Joy.ApiTokens.touch_last_used(token_id) end)
      conn
      |> assign(:current_scope, Joy.Accounts.Scope.for_user(user))
      |> assign(:api_token_id, token_id)
    else
      _ ->
        conn
        |> put_status(:unauthorized)
        |> json(%{errors: %{detail: "Invalid or missing API token"}})
        |> halt()
    end
  end
end
