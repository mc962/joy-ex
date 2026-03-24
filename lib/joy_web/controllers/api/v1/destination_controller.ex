defmodule JoyWeb.API.V1.DestinationController do
  use JoyWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Joy.Channels
  alias JoyWeb.API.Schemas

  action_fallback JoyWeb.FallbackController

  tags ["Destinations"]
  security [%{"BearerAuth" => []}]

  operation :index,
    summary: "List destinations for a channel",
    parameters: [channel_id: [in: :path, type: :integer, required: true]],
    responses: [ok: {"Destination list", "application/json", Schemas.DestinationList}]

  def index(conn, %{"channel_id" => channel_id}) do
    with {:ok, channel} <- fetch_channel(channel_id) do
      json(conn, %{data: Enum.map(channel.destination_configs, &serialize/1)})
    end
  end

  operation :create,
    summary: "Create a destination",
    parameters: [channel_id: [in: :path, type: :integer, required: true]],
    request_body: {"Destination params", "application/json", Schemas.DestinationParams},
    responses: [
      created: {"Created destination", "application/json", Schemas.DestinationResponse},
      unprocessable_entity: {"Validation errors", "application/json", Schemas.ErrorResponse}
    ]

  def create(conn, %{"channel_id" => channel_id, "destination" => params}) do
    with :ok <- require_admin(conn),
         {:ok, _channel} <- fetch_channel(channel_id),
         {:ok, dest} <- Channels.upsert_destination_config(String.to_integer(channel_id), params) do
      conn
      |> put_status(:created)
      |> json(%{data: serialize(dest)})
    end
  end

  operation :update,
    summary: "Update a destination",
    parameters: [
      channel_id: [in: :path, type: :integer, required: true],
      id: [in: :path, type: :integer, required: true]
    ],
    request_body: {"Destination params", "application/json", Schemas.DestinationParams},
    responses: [
      ok: {"Updated destination", "application/json", Schemas.DestinationResponse},
      not_found: {"Not found", "application/json", Schemas.ErrorResponse}
    ]

  def update(conn, %{"channel_id" => channel_id, "id" => id, "destination" => params}) do
    with :ok <- require_admin(conn),
         {:ok, channel} <- fetch_channel(channel_id),
         {:ok, dest} <- fetch_dest(channel, id),
         {:ok, updated} <- Channels.upsert_destination_config(channel.id, Map.put(params, "id", dest.id)) do
      json(conn, %{data: serialize(updated)})
    end
  end

  operation :delete,
    summary: "Delete a destination",
    parameters: [
      channel_id: [in: :path, type: :integer, required: true],
      id: [in: :path, type: :integer, required: true]
    ],
    responses: [
      no_content: "Deleted",
      not_found: {"Not found", "application/json", Schemas.ErrorResponse}
    ]

  def delete(conn, %{"channel_id" => channel_id, "id" => id}) do
    with :ok <- require_admin(conn),
         {:ok, channel} <- fetch_channel(channel_id),
         {:ok, dest} <- fetch_dest(channel, id),
         {:ok, _} <- Channels.delete_destination_config(dest) do
      send_resp(conn, :no_content, "")
    end
  end

  defp fetch_channel(id) do
    try do
      {:ok, Channels.get_channel!(String.to_integer(id))}
    rescue
      Ecto.NoResultsError -> {:error, :not_found}
      ArgumentError -> {:error, :not_found}
    end
  end

  defp fetch_dest(channel, id) do
    case Enum.find(channel.destination_configs, &(to_string(&1.id) == id)) do
      nil  -> {:error, :not_found}
      dest -> {:ok, dest}
    end
  end

  defp require_admin(conn) do
    if conn.assigns.current_scope.user.is_admin, do: :ok, else: {:error, :unauthorized}
  end

  # config is excluded — it may contain credentials
  defp serialize(dest) do
    %{
      id:              dest.id,
      channel_id:      dest.channel_id,
      name:            dest.name,
      adapter:         dest.adapter,
      retry_attempts:  dest.retry_attempts,
      retry_base_ms:   dest.retry_base_ms,
      enabled:         dest.enabled,
      inserted_at:     dest.inserted_at,
      updated_at:      dest.updated_at
    }
  end
end
