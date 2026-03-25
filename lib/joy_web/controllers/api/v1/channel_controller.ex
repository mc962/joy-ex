defmodule JoyWeb.API.V1.ChannelController do
  use JoyWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Joy.Channels
  alias Joy.ChannelManager
  alias JoyWeb.API.Schemas

  action_fallback JoyWeb.FallbackController

  tags ["Channels"]
  security [%{"BearerAuth" => []}]

  operation :index,
    summary: "List channels",
    responses: [ok: {"Channel list", "application/json", Schemas.ChannelList}]

  def index(conn, _params) do
    channels = Channels.list_channels(conn.assigns.current_scope)
    json(conn, %{data: Enum.map(channels, &serialize/1)})
  end

  operation :show,
    summary: "Get a channel",
    parameters: [id: [in: :path, type: :integer, required: true]],
    responses: [
      ok: {"Channel", "application/json", Schemas.ChannelResponse},
      not_found: {"Not found", "application/json", Schemas.ErrorResponse}
    ]

  def show(conn, %{"id" => id}) do
    with {:ok, channel} <- fetch_channel(id, conn.assigns.current_scope) do
      json(conn, %{data: serialize(channel)})
    end
  end

  operation :create,
    summary: "Create a channel",
    request_body: {"Channel params", "application/json", Schemas.ChannelParams},
    responses: [
      created: {"Created channel", "application/json", Schemas.ChannelResponse},
      unprocessable_entity: {"Validation errors", "application/json", Schemas.ErrorResponse}
    ]

  def create(conn, %{"channel" => params}) do
    with :ok <- require_admin(conn),
         {:ok, channel} <- Channels.create_channel(params) do
      conn
      |> put_status(:created)
      |> json(%{data: serialize(channel)})
    end
  end

  operation :update,
    summary: "Update a channel",
    parameters: [id: [in: :path, type: :integer, required: true]],
    request_body: {"Channel params", "application/json", Schemas.ChannelParams},
    responses: [
      ok: {"Updated channel", "application/json", Schemas.ChannelResponse},
      not_found: {"Not found", "application/json", Schemas.ErrorResponse}
    ]

  def update(conn, %{"id" => id, "channel" => params}) do
    with :ok <- require_admin(conn),
         {:ok, channel} <- fetch_channel(id, conn.assigns.current_scope),
         {:ok, updated} <- Channels.update_channel(channel, params) do
      json(conn, %{data: serialize(updated)})
    end
  end

  operation :delete,
    summary: "Delete a channel",
    parameters: [id: [in: :path, type: :integer, required: true]],
    responses: [
      no_content: "Deleted",
      not_found: {"Not found", "application/json", Schemas.ErrorResponse}
    ]

  def delete(conn, %{"id" => id}) do
    with :ok <- require_admin(conn),
         {:ok, channel} <- fetch_channel(id, conn.assigns.current_scope),
         {:ok, _} <- Channels.delete_channel(channel) do
      send_resp(conn, :no_content, "")
    end
  end

  operation :start,
    summary: "Start a channel",
    parameters: [channel_id: [in: :path, type: :integer, required: true]],
    responses: [ok: {"Status", "application/json", Schemas.StatusResponse}]

  def start(conn, %{"channel_id" => id}) do
    with :ok <- require_admin(conn),
         {:ok, channel} <- fetch_channel(id, conn.assigns.current_scope) do
      ChannelManager.start_channel(channel)
      Channels.set_started(channel, true)
      json(conn, %{data: %{status: "started"}})
    end
  end

  operation :stop,
    summary: "Stop a channel",
    parameters: [channel_id: [in: :path, type: :integer, required: true]],
    responses: [ok: {"Status", "application/json", Schemas.StatusResponse}]

  def stop(conn, %{"channel_id" => id}) do
    with :ok <- require_admin(conn),
         {:ok, channel} <- fetch_channel(id, conn.assigns.current_scope) do
      ChannelManager.stop_channel(channel.id)
      Channels.set_started(channel, false)
      json(conn, %{data: %{status: "stopped"}})
    end
  end

  operation :pause,
    summary: "Pause a channel",
    parameters: [channel_id: [in: :path, type: :integer, required: true]],
    responses: [ok: {"Status", "application/json", Schemas.StatusResponse}]

  def pause(conn, %{"channel_id" => id}) do
    with :ok <- require_admin(conn),
         {:ok, channel} <- fetch_channel(id, conn.assigns.current_scope) do
      ChannelManager.pause_channel(channel.id)
      json(conn, %{data: %{status: "paused"}})
    end
  end

  operation :resume,
    summary: "Resume a paused channel",
    parameters: [channel_id: [in: :path, type: :integer, required: true]],
    responses: [ok: {"Status", "application/json", Schemas.StatusResponse}]

  def resume(conn, %{"channel_id" => id}) do
    with :ok <- require_admin(conn),
         {:ok, channel} <- fetch_channel(id, conn.assigns.current_scope) do
      ChannelManager.resume_channel(channel.id)
      json(conn, %{data: %{status: "resumed"}})
    end
  end

  defp fetch_channel(id, scope) do
    try do
      {:ok, Channels.get_channel!(String.to_integer(id), scope)}
    rescue
      Ecto.NoResultsError -> {:error, :not_found}
      ArgumentError -> {:error, :not_found}
    end
  end

  defp require_admin(conn) do
    if Joy.Accounts.Scope.admin?(conn.assigns.current_scope), do: :ok, else: {:error, :unauthorized}
  end

  defp serialize(channel) do
    %{
      id:                   channel.id,
      name:                 channel.name,
      description:          channel.description,
      mllp_port:            channel.mllp_port,
      started:              channel.started,
      paused:               channel.paused,
      running:              ChannelManager.channel_running?(channel.id),
      dispatch_concurrency: channel.dispatch_concurrency,
      pinned_node:          channel.pinned_node,
      allowed_ips:          channel.allowed_ips,
      organization_id:      channel.organization_id,
      tls_enabled:          channel.tls_enabled,
      tls_verify_peer:      channel.tls_verify_peer,
      tls_cert_expires_at:  channel.tls_cert_expires_at,
      alert_enabled:        channel.alert_enabled,
      alert_threshold:      channel.alert_threshold,
      alert_email:          channel.alert_email,
      alert_webhook_url:    channel.alert_webhook_url,
      alert_cooldown_minutes: channel.alert_cooldown_minutes,
      ack_code_override:    channel.ack_code_override,
      ack_sending_app:      channel.ack_sending_app,
      ack_sending_fac:      channel.ack_sending_fac,
      inserted_at:          channel.inserted_at,
      updated_at:           channel.updated_at
    }
  end
end
