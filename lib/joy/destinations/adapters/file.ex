defmodule Joy.Destinations.Adapters.File do
  @moduledoc """
  Destination adapter: appends the HL7 message to a local file.

  Primarily useful for debugging, audit trails, and integration testing.
  Each message is separated by a blank line for readability.

  Config map keys:
  - "path"   — required, absolute path to the output file
  - "format" — optional, "hl7" (default) or "json"

  # GO-TRANSLATION: Use os.OpenFile with O_APPEND|O_WRONLY|O_CREATE flags.
  # Use a sync.Mutex if this adapter is called concurrently.
  """

  @behaviour Joy.Destinations.Destination

  require Logger

  @impl true
  def adapter_name, do: "file"

  @impl true
  def validate_config(config) do
    if Map.get(config, "path") && Map.get(config, "path") != "",
      do: :ok,
      else: {:error, "path is required"}
  end

  @impl true
  def deliver(msg, config) do
    path = Map.fetch!(config, "path")
    format = Map.get(config, "format", "hl7")

    content = format_message(msg, format)

    case Elixir.File.write(path, content <> "\n\n", [:append, :utf8]) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("[FileAdapter] Write failed to #{path}: #{inspect(reason)}")
        {:error, "File write error: #{:file.format_error(reason)}"}
    end
  end

  defp format_message(msg, "json") do
    Jason.encode!(%{
      hl7: Joy.HL7.to_string(msg),
      message_type: Joy.HL7.get(msg, "MSH.9"),
      message_control_id: Joy.HL7.get(msg, "MSH.10"),
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }, pretty: true)
  end

  defp format_message(msg, _hl7) do
    Joy.HL7.to_string(msg)
  end
end
