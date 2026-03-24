defmodule JoyWeb.API.V1.TokenController do
  use JoyWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias JoyWeb.API.Schemas

  action_fallback JoyWeb.FallbackController

  tags ["Tokens"]

  operation :create,
    summary: "Create an API token",
    description: "Authenticates with email and password and returns a new Bearer token. " <>
                 "The token is shown once — store it securely. " <>
                 "Maximum 10 active tokens per user.",
    request_body: {"Token params", "application/json", Schemas.TokenParams},
    responses: [
      created: {"Created token", "application/json", Schemas.TokenCreatedResponse},
      unauthorized: {"Invalid credentials", "application/json", Schemas.ErrorResponse},
      unprocessable_entity: {"Token limit reached", "application/json", Schemas.ErrorResponse}
    ]

  def create(conn, %{"email" => email, "password" => password} = params) do
    with {:ok, user} <- authenticate(email, password),
         {:ok, {plain, token}} <- Joy.ApiTokens.create_token(user, params) do
      conn
      |> put_status(:created)
      |> json(%{data: serialize(plain, token)})
    end
  end

  operation :delete,
    summary: "Revoke an API token",
    description: "Revokes any of the authenticated user's tokens by id.",
    parameters: [id: [in: :path, type: :integer, required: true]],
    responses: [
      no_content: "Revoked",
      not_found: {"Not found", "application/json", Schemas.ErrorResponse}
    ]

  def delete(conn, %{"id" => id}) do
    with {:ok, _} <- Joy.ApiTokens.revoke_token(conn.assigns.current_scope.user, id) do
      send_resp(conn, :no_content, "")
    end
  end

  defp authenticate(email, password) do
    case Joy.Accounts.get_user_by_email_and_password(email, password) do
      nil  -> {:error, :invalid_credentials}
      user -> {:ok, user}
    end
  end

  defp serialize(plain, token) do
    %{
      id:         token.id,
      name:       token.name,
      token:      plain,
      expires_at: token.expires_at
    }
  end
end
