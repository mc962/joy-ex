defmodule Joy.Destinations.Adapters.FileAdapter do
  @moduledoc """
  Destination adapter: File. Appends HL7 messages to a local file.
  Useful for debugging, audit trails, and local testing.

  Config: "path" (required), "format" ("raw" or "json", default "raw").

  # GO-TRANSLATION: os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644).
  # File.write/3 with [:append, :sync] is the Elixir equivalent.
  """

  @behaviour Joy.Destinations.Destination

  @impl true
  def adapter_name, do: "file"

  @impl true
  def deliver(msg, config) do
    path = config["path"]
    format = Map.get(config, "format", "raw")

    File.mkdir_p!(Path.dirname(path))

    content =
      case format do
        "json" ->
          Jason.encode!(%{
            timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
            message_type: Joy.HL7.get(msg, "MSH.9"),
            sending_facility: Joy.HL7.get(msg, "MSH.4"),
            hl7: Joy.HL7.to_string(msg)
          }) <> "\n"

        _ ->
          Joy.HL7.to_string(msg) <> "\n---\n"
      end

    case File.write(path, content, [:append, :sync]) do
      :ok -> :ok
      {:error, reason} -> {:error, "File write failed: #{:file.format_error(reason)}"}
    end
  end

  @impl true
  def validate_config(config) do
    if config["path"] && config["path"] != "",
      do: :ok,
      else: {:error, "path is required"}
  end
end
