defmodule JoyWeb.API.V1.MessageLogController do
  use JoyWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Joy.MessageLog
  alias Joy.Channels
  alias JoyWeb.API.Schemas

  action_fallback JoyWeb.FallbackController

  tags ["Message Log"]
  security [%{"BearerAuth" => []}]

  operation :index,
    summary: "List message log entries for a channel",
    parameters: [
      channel_id:   [in: :path,  type: :integer, required: true],
      limit:        [in: :query, type: :integer, description: "Max results (default 50, max 1000)"],
      status:       [in: :query, type: :string,  description: "Filter by status: pending, processed, failed, retried"],
      message_type: [in: :query, type: :string,  description: "Substring match on MSH.9"],
      patient_id:   [in: :query, type: :string,  description: "Substring match on PID.3"]
    ],
    responses: [ok: {"Message log entries", "application/json", Schemas.MessageLogList}]

  def index(conn, %{"channel_id" => channel_id} = params) do
    with {:ok, _channel} <- fetch_channel(channel_id) do
      opts = [
        limit:        min(parse_int(params["limit"], 50), 1000),
        status:       params["status"],
        message_type: params["message_type"],
        patient_id:   params["patient_id"]
      ]
      entries = MessageLog.list_recent(String.to_integer(channel_id), opts)
      json(conn, %{data: Enum.map(entries, &serialize/1)})
    end
  end

  operation :retry,
    summary: "Retry a failed message log entry",
    parameters: [
      channel_id:     [in: :path, type: :integer, required: true],
      message_log_id: [in: :path, type: :integer, required: true]
    ],
    responses: [
      created: {"New entry created for retry", "application/json", Schemas.MessageLogEntryResponse},
      not_found: {"Not found", "application/json", Schemas.ErrorResponse}
    ]

  def retry(conn, %{"channel_id" => channel_id, "message_log_id" => entry_id}) do
    with :ok <- require_admin(conn),
         {:ok, _channel} <- fetch_channel(channel_id),
         {:ok, entry} <- fetch_entry(channel_id, entry_id),
         {:ok, new_entry} <- MessageLog.retry_entry(entry) do
      conn
      |> put_status(:created)
      |> json(%{data: serialize(new_entry)})
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

  defp fetch_entry(channel_id, entry_id) do
    alias Joy.MessageLog.Entry
    alias Joy.Repo

    case Repo.get_by(Entry, id: entry_id, channel_id: String.to_integer(channel_id)) do
      nil   -> {:error, :not_found}
      entry -> {:ok, entry}
    end
  end

  defp require_admin(conn) do
    if Joy.Accounts.Scope.admin?(conn.assigns.current_scope), do: :ok, else: {:error, :unauthorized}
  end

  defp parse_int(nil, default), do: default
  defp parse_int(str, default) do
    case Integer.parse(str) do
      {n, _} when n > 0 -> n
      _                  -> default
    end
  end

  defp serialize(entry) do
    %{
      id:                 entry.id,
      channel_id:         entry.channel_id,
      message_control_id: entry.message_control_id,
      status:             entry.status,
      message_type:       entry.message_type,
      patient_id:         entry.patient_id,
      error:              entry.error,
      inserted_at:        entry.inserted_at
    }
  end
end
