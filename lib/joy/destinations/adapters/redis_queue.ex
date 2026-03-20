defmodule Joy.Destinations.Adapters.RedisQueue do
  @moduledoc """
  Destination adapter: Redis list or stream. Config: "redis_url", "key",
  "type" ("list" or "stream", default "list").

  Opens a fresh Redix connection per delivery (stateless adapter).
  For high-throughput channels, a pooled connection should be considered.

  # GO-TRANSLATION: go-redis client; Redix commands map 1:1 to Redis commands.
  """

  @behaviour Joy.Destinations.Destination

  @impl true
  def adapter_name, do: "redis_queue"

  @impl true
  def deliver(msg, config) do
    key = config["key"]
    type = Map.get(config, "type", "list")
    raw = Joy.HL7.to_string(msg)

    payload = Jason.encode!(%{
      hl7: raw,
      message_type: Joy.HL7.get(msg, "MSH.9"),
      sending_facility: Joy.HL7.get(msg, "MSH.4"),
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    })

    with {:ok, conn} <- Redix.start_link(config["redis_url"]) do
      result =
        case type do
          "stream" ->
            msg_type = Joy.HL7.get(msg, "MSH.9") || ""
            Redix.command(conn, ["XADD", key, "*", "hl7", raw, "message_type", msg_type,
                                  "timestamp", DateTime.utc_now() |> DateTime.to_iso8601()])
          _ ->
            Redix.command(conn, ["LPUSH", key, payload])
        end

      Redix.stop(conn)

      case result do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, "Redis error: #{inspect(reason)}"}
      end
    else
      {:error, reason} -> {:error, "Redis connect failed: #{inspect(reason)}"}
    end
  end

  @impl true
  def validate_config(config) do
    cond do
      !config["redis_url"] || config["redis_url"] == "" -> {:error, "redis_url is required"}
      !config["key"] || config["key"] == "" -> {:error, "key is required"}
      true -> :ok
    end
  end
end
