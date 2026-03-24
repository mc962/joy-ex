defmodule JoyWeb.API.V1.OrganizationController do
  use JoyWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Joy.Organizations
  alias JoyWeb.API.Schemas

  action_fallback JoyWeb.FallbackController

  tags ["Organizations"]
  security [%{"BearerAuth" => []}]

  operation :index,
    summary: "List organizations",
    responses: [ok: {"Organization list", "application/json", Schemas.OrganizationList}]

  def index(conn, _params) do
    orgs = Organizations.list_organizations()
    json(conn, %{data: Enum.map(orgs, &serialize/1)})
  end

  operation :show,
    summary: "Get an organization",
    parameters: [id: [in: :path, type: :integer, required: true]],
    responses: [
      ok: {"Organization", "application/json", Schemas.OrganizationResponse},
      not_found: {"Not found", "application/json", Schemas.ErrorResponse}
    ]

  def show(conn, %{"id" => id}) do
    with {:ok, org} <- fetch_org(id) do
      json(conn, %{data: serialize(org)})
    end
  end

  operation :create,
    summary: "Create an organization",
    request_body: {"Organization params", "application/json", Schemas.OrganizationParams},
    responses: [
      created: {"Created organization", "application/json", Schemas.OrganizationResponse},
      unprocessable_entity: {"Validation errors", "application/json", Schemas.ErrorResponse}
    ]

  def create(conn, %{"organization" => params}) do
    with :ok <- require_admin(conn),
         {:ok, org} <- Organizations.create_organization(params) do
      conn
      |> put_status(:created)
      |> json(%{data: serialize(org)})
    end
  end

  operation :update,
    summary: "Update an organization",
    parameters: [id: [in: :path, type: :integer, required: true]],
    request_body: {"Organization params", "application/json", Schemas.OrganizationParams},
    responses: [
      ok: {"Updated organization", "application/json", Schemas.OrganizationResponse},
      not_found: {"Not found", "application/json", Schemas.ErrorResponse}
    ]

  def update(conn, %{"id" => id, "organization" => params}) do
    with :ok <- require_admin(conn),
         {:ok, org} <- fetch_org(id),
         {:ok, updated} <- Organizations.update_organization(org, params) do
      json(conn, %{data: serialize(updated)})
    end
  end

  operation :delete,
    summary: "Delete an organization",
    parameters: [id: [in: :path, type: :integer, required: true]],
    responses: [
      no_content: "Deleted",
      not_found: {"Not found", "application/json", Schemas.ErrorResponse}
    ]

  def delete(conn, %{"id" => id}) do
    with :ok <- require_admin(conn),
         {:ok, org} <- fetch_org(id),
         {:ok, _} <- Organizations.delete_organization(org) do
      send_resp(conn, :no_content, "")
    end
  end

  defp fetch_org(id) do
    try do
      {:ok, Organizations.get_organization!(String.to_integer(id))}
    rescue
      Ecto.NoResultsError -> {:error, :not_found}
      ArgumentError -> {:error, :not_found}
    end
  end

  defp require_admin(conn) do
    if conn.assigns.current_scope.user.is_admin, do: :ok, else: {:error, :unauthorized}
  end

  defp serialize(org) do
    %{
      id:          org.id,
      name:        org.name,
      inserted_at: org.inserted_at,
      updated_at:  org.updated_at
    }
  end
end
