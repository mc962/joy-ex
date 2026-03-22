defmodule Joy.MLLP.Connection do
  @moduledoc """
  Handles a single MLLP TCP (or TLS) client connection via ThousandIsland.Handler.

  Message flow (guaranteeing at-least-once delivery):
    1. Receive data via handle_data/3 callback (ThousandIsland manages the recv loop)
    2. Buffer and extract complete MLLP frames via Joy.MLLP.Framer.unwrap/1
    3. Parse HL7 with Joy.HL7.Parser
    4. Persist to message_log as :pending BEFORE ACKing
    5. Send ACK (AA on success, AE on error) via ThousandIsland.Socket.send/2
    6. Dispatch to Joy.Channel.Pipeline async

  ThousandIsland abstracts TCP vs TLS — ThousandIsland.Socket.send/2 and
  ThousandIsland.Socket.peername/1 work identically for both transports.

  Why persist before ACKing: if we crash after persisting but before processing,
  the pipeline requeues on restart. If we crash before persisting, the sender
  retries (no ACK = retry). This guarantees no message is silently dropped.

  # GO-TRANSLATION:
  # goroutine per connection reading from net.Conn synchronously.
  # ThousandIsland.Handler callbacks replace the Go read loop.
  """

  use ThousandIsland.Handler
  import Bitwise
  require Logger

  @impl ThousandIsland.Handler
  def handle_connection(socket, %{channel_id: channel_id} = state) do
    channel =
      Joy.Repo.get!(Joy.Channels.Channel, channel_id)
      |> Joy.Repo.preload(:organization)

    case check_peer_ip(socket, Joy.Channels.effective_allowed_ips(channel)) do
      :ok ->
        {:continue, Map.merge(state, %{channel: channel, buffer: ""})}

      {:rejected, peer_ip} ->
        Logger.warning("[MLLP.Connection] Rejected connection from #{peer_ip} — not in allowlist for channel #{channel_id}")
        {:close, state}
    end
  end

  @impl ThousandIsland.Handler
  def handle_data(data, socket, state) do
    Joy.ChannelStats.incr_received(state.channel_id)
    new_buffer = process_buffer(state.buffer <> data, socket, state)
    {:continue, %{state | buffer: new_buffer}}
  end

  @impl ThousandIsland.Handler
  def handle_close(_socket, state) do
    transport_label = if Map.get(state, :channel), do: "TLS client", else: "Client"
    Logger.debug("[MLLP.Connection] #{transport_label} disconnected (channel #{state.channel_id})")
  end

  @impl ThousandIsland.Handler
  def handle_error(reason, _socket, state) do
    Logger.warning("[MLLP.Connection] Error on channel #{state.channel_id}: #{inspect(reason)}")
  end

  # Returns the remaining buffer after processing all complete frames.
  defp process_buffer(buffer, socket, state) do
    case Joy.MLLP.Framer.unwrap(buffer) do
      {:ok, hl7_string, rest} ->
        handle_message(hl7_string, socket, state)
        process_buffer(rest, socket, state)

      :incomplete ->
        buffer

      {:error, _} ->
        Logger.warning("[MLLP.Connection] Invalid MLLP frame, clearing buffer")
        ""
    end
  end

  defp handle_message(raw_hl7, socket, state) do
    case Joy.HL7.Parser.parse(raw_hl7) do
      {:ok, msg} ->
        message_control_id = Joy.HL7.get(msg, "MSH.10") || generate_control_id()

        case Joy.MessageLog.persist_pending(state.channel_id, message_control_id, raw_hl7) do
          {:ok, %{id: nil}} ->
            # Duplicate — already persisted (same message_control_id). Just ACK.
            send_ack(socket, msg, :aa)

          {:ok, entry} ->
            send_ack(socket, msg, :aa)
            dispatch_to_pipeline(state.channel_id, entry.id)

          {:error, reason} ->
            Logger.error("[MLLP.Connection] Failed to persist message: #{inspect(reason)}")
            send_ack(socket, msg, :ae)
        end

      {:error, reason} ->
        Logger.error("[MLLP.Connection] Failed to parse HL7: #{inspect(reason)}")
        ThousandIsland.Socket.send(socket, minimal_ae_ack())
    end
  end

  defp send_ack(socket, msg, code) do
    ThousandIsland.Socket.send(socket, Joy.MLLP.Framer.build_ack(msg, code))
  end

  defp dispatch_to_pipeline(channel_id, entry_id) do
    case Horde.Registry.lookup(Joy.ChannelRegistry, {:pipeline, channel_id}) do
      [{pid, _}] -> GenServer.cast(pid, {:process, entry_id})
      [] -> Logger.warning("[MLLP.Connection] Pipeline not found for channel #{channel_id}")
    end
  end

  defp generate_control_id do
    :crypto.strong_rand_bytes(6) |> Base.encode16()
  end

  defp check_peer_ip(_socket, []), do: :ok

  defp check_peer_ip(socket, allowed_ips) do
    case ThousandIsland.Socket.peername(socket) do
      {:ok, {ip_tuple, _port}} ->
        peer_str = ip_tuple |> :inet.ntoa() |> to_string()
        if Enum.any?(allowed_ips, &ip_matches?(peer_str, ip_tuple, &1)),
          do: :ok,
          else: {:rejected, peer_str}

      {:error, _} ->
        # Can't determine peer address; allow rather than silently drop.
        :ok
    end
  end

  defp ip_matches?(peer_str, peer_tuple, entry) do
    case String.split(entry, "/", parts: 2) do
      [ip] -> peer_str == ip
      [network_str, prefix_str] -> cidr_match?(peer_tuple, network_str, String.to_integer(prefix_str))
    end
  end

  defp cidr_match?({a, b, c, d}, network_str, prefix_len) when prefix_len in 0..32 do
    case :inet.parse_address(to_charlist(network_str)) do
      {:ok, {na, nb, nc, nd}} ->
        mask = (0xFFFFFFFF <<< (32 - prefix_len)) &&& 0xFFFFFFFF
        peer_int = a * 0x1000000 + b * 0x10000 + c * 0x100 + d
        net_int = na * 0x1000000 + nb * 0x10000 + nc * 0x100 + nd
        (peer_int &&& mask) == (net_int &&& mask)

      _ ->
        false
    end
  end

  defp cidr_match?(_, _, _), do: false

  defp minimal_ae_ack do
    msg = "MSH|^~\\&|Joy|||||||#{DateTime.utc_now() |> Calendar.strftime("%Y%m%d%H%M%S")}||ACK|#{generate_control_id()}|P|2.5\rMSA|AE|\r"
    Joy.MLLP.Framer.wrap(msg)
  end
end
