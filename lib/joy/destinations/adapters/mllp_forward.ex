defmodule Joy.Destinations.Adapters.MllpForward do
  @moduledoc """
  Destination adapter: MLLP Forward. Sends HL7 to another MLLP endpoint.

  Opens a fresh TCP connection per message (stateless — avoids connection state
  management complexity for an adapter). Config: "host", "port", "timeout_ms".

  # GO-TRANSLATION: net.DialTimeout + conn.Write/Read. Near-identical structure.
  """

  @behaviour Joy.Destinations.Destination

  @impl true
  def adapter_name, do: "mllp_forward"

  @impl true
  def deliver(msg, config) do
    host = String.to_charlist(config["host"])
    port = config["port"]
    timeout = Map.get(config, "timeout_ms", 10_000)
    raw = Joy.HL7.to_string(msg)

    with {:ok, socket} <- :gen_tcp.connect(host, port, [:binary, packet: :raw, active: false], timeout),
         :ok <- :gen_tcp.send(socket, Joy.MLLP.Framer.wrap(raw)),
         {:ok, ack_data} <- :gen_tcp.recv(socket, 0, timeout),
         :ok <- :gen_tcp.close(socket),
         {:ok, ack_hl7, _} <- Joy.MLLP.Framer.unwrap(ack_data),
         {:ok, ack_msg} <- Joy.HL7.Parser.parse(ack_hl7) do
      msa_code = Joy.HL7.get(ack_msg, "MSA.1")
      if msa_code == "AA", do: :ok, else: {:error, "NACK from upstream: #{msa_code}"}
    else
      {:error, reason} -> {:error, "MLLP forward failed: #{inspect(reason)}"}
    end
  end

  @impl true
  def validate_config(config) do
    cond do
      !config["host"] || config["host"] == "" -> {:error, "host is required"}
      !config["port"] -> {:error, "port is required"}
      true -> :ok
    end
  end
end
