defmodule JoyWeb.API.V1.RetentionController do
  use JoyWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias JoyWeb.API.Schemas

  action_fallback JoyWeb.FallbackController

  tags ["Retention"]
  security [%{"BearerAuth" => []}]

  operation :purge,
    summary: "Trigger a message log retention purge",
    description: "Runs archive (if configured) then deletes eligible entries. Admin only. Synchronous.",
    responses: [
      ok: {"Purge result", "application/json", Schemas.PurgeResult},
      forbidden: {"Admin required", "application/json", Schemas.ErrorResponse}
    ]

  def purge(conn, _params) do
    with :ok <- require_admin(conn),
         {:ok, result} <- Joy.Retention.run_purge() do
      json(conn, %{data: %{deleted: result.deleted, archived: result.archived}})
    end
  end

  defp require_admin(conn) do
    if conn.assigns.current_scope.user.is_admin, do: :ok, else: {:error, :unauthorized}
  end
end
