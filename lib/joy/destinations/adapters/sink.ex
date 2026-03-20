defmodule Joy.Destinations.Adapters.Sink do
  @moduledoc """
  Destination adapter: Message Sink. Captures messages in-memory for testing.

  Zero infrastructure required — messages are stored in Joy.Sinks (a GenServer)
  and inspectable in real-time via the Sinks UI at /tools/sinks.

  Config: "name" — the sink identifier (e.g. "audit", "lab_feed").
  Multiple channels can share a sink name or use separate ones.

  # GO-TRANSLATION: Simple channel send instead of GenServer.cast.
  """

  @behaviour Joy.Destinations.Destination

  @impl true
  def adapter_name, do: "sink"

  @impl true
  def deliver(msg, config) do
    name = config["name"] || "default"
    Joy.Sinks.push(name, msg)
    :ok
  end

  @impl true
  def validate_config(config) do
    if config["name"] && config["name"] != "" do
      :ok
    else
      {:error, "name is required"}
    end
  end
end
