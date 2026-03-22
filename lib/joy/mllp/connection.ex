defmodule Joy.MLLP.Connection do
  @moduledoc """
  Handles a single MLLP TCP (or TLS) client connection.

  Message flow (guaranteeing at-least-once delivery):
    1. Receive TCP/SSL data, buffer partial frames
    2. Extract complete MLLP frames via Joy.MLLP.Framer.unwrap/1
    3. Parse HL7 with Joy.HL7.Parser
    4. Persist to message_log as :pending BEFORE ACKing
    5. Send ACK (AA on success, AE on error)
    6. Dispatch to Joy.Channel.Pipeline async

  Transport abstraction:
    - gen_tcp: messages arrive as {:tcp, socket, data}, {:tcp_closed, _}, {:tcp_error, _, _}
    - ssl: messages arrive as {:ssl, socket, data}, {:ssl_closed, _}, {:ssl_error, _, _}
    - active mode is set via :inet.setopts (gen_tcp) or :ssl.setopts (ssl)

  Why persist before ACKing: if we crash after persisting but before processing,
  the pipeline requeues on restart. If we crash before persisting, the sender
  retries (no ACK = retry). This guarantees no message is silently dropped.

  restart: :temporary — connections are transient, not worth restarting after disconnect.

  # GO-TRANSLATION:
  # goroutine per connection reading from net.Conn synchronously.
  # TCP active mode (messages arrive as process messages) has no Go equivalent —
  # Go reads with conn.Read() in a loop. Conceptually identical, syntactically different.
  """

  use GenServer
  import Bitwise
  require Logger

  def start_link({channel_id, socket, transport}) do
    GenServer.start_link(__MODULE__, {channel_id, socket, transport})
  end

  def child_spec({channel_id, socket, transport}) do
    %{
      id: {__MODULE__, :erlang.unique_integer()},
      start: {__MODULE__, :start_link, [{channel_id, socket, transport}]},
      restart: :temporary,
      type: :worker
    }
  end

  @impl true
  def init({channel_id, socket, transport}) do
    channel = Joy.Repo.get!(Joy.Channels.Channel, channel_id)

    case check_peer_ip(socket, channel.allowed_ips, transport) do
      :ok ->
        set_active(socket, transport)
        {:ok, %{channel_id: channel_id, socket: socket, buffer: "", transport: transport}}

      {:rejected, peer_ip} ->
        Logger.warning("[MLLP.Connection] Rejected connection from #{peer_ip} — not in allowlist for channel #{channel_id}")
        close(socket, transport)
        {:stop, :normal}
    end
  end

  @impl true
  # gen_tcp active mode messages
  def handle_info({:tcp, _socket, data}, state) do
    Joy.ChannelStats.incr_received(state.channel_id)
    new_state = process_buffer(%{state | buffer: state.buffer <> data})
    {:noreply, new_state}
  end

  def handle_info({:tcp_closed, _socket}, state) do
    Logger.debug("[MLLP.Connection] Client disconnected (channel #{state.channel_id})")
    {:stop, :normal, state}
  end

  def handle_info({:tcp_error, _socket, reason}, state) do
    Logger.warning("[MLLP.Connection] TCP error on channel #{state.channel_id}: #{inspect(reason)}")
    {:stop, reason, state}
  end

  # ssl active mode messages
  def handle_info({:ssl, _socket, data}, state) do
    Joy.ChannelStats.incr_received(state.channel_id)
    new_state = process_buffer(%{state | buffer: state.buffer <> data})
    {:noreply, new_state}
  end

  def handle_info({:ssl_closed, _socket}, state) do
    Logger.debug("[MLLP.Connection] TLS client disconnected (channel #{state.channel_id})")
    {:stop, :normal, state}
  end

  def handle_info({:ssl_error, _socket, reason}, state) do
    Logger.warning("[MLLP.Connection] TLS error on channel #{state.channel_id}: #{inspect(reason)}")
    {:stop, reason, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp process_buffer(state) do
    case Joy.MLLP.Framer.unwrap(state.buffer) do
      {:ok, hl7_string, rest} ->
        handle_message(hl7_string, state)
        process_buffer(%{state | buffer: rest})

      :incomplete ->
        state

      {:error, _} ->
        Logger.warning("[MLLP.Connection] Invalid MLLP frame, clearing buffer")
        %{state | buffer: ""}
    end
  end

  defp handle_message(raw_hl7, state) do
    case Joy.HL7.Parser.parse(raw_hl7) do
      {:ok, msg} ->
        message_control_id = Joy.HL7.get(msg, "MSH.10") || generate_control_id()

        case Joy.MessageLog.persist_pending(state.channel_id, message_control_id, raw_hl7) do
          {:ok, %{id: nil}} ->
            # Duplicate — already persisted (same message_control_id). Just ACK.
            send_ack(state.socket, state.transport, msg, :aa)

          {:ok, entry} ->
            send_ack(state.socket, state.transport, msg, :aa)
            dispatch_to_pipeline(state.channel_id, entry.id)

          {:error, reason} ->
            Logger.error("[MLLP.Connection] Failed to persist message: #{inspect(reason)}")
            send_ack(state.socket, state.transport, msg, :ae)
        end

      {:error, reason} ->
        Logger.error("[MLLP.Connection] Failed to parse HL7: #{inspect(reason)}")
        send_raw(state.socket, state.transport, minimal_ae_ack())
    end
  end

  defp send_ack(socket, transport, msg, code) do
    ack = Joy.MLLP.Framer.build_ack(msg, code)
    send_raw(socket, transport, ack)
  end

  defp send_raw(socket, :gen_tcp, data), do: :gen_tcp.send(socket, data)
  defp send_raw(socket, :ssl, data), do: :ssl.send(socket, data)

  defp dispatch_to_pipeline(channel_id, entry_id) do
    case Horde.Registry.lookup(Joy.ChannelRegistry, {:pipeline, channel_id}) do
      [{pid, _}] -> GenServer.cast(pid, {:process, entry_id})
      [] -> Logger.warning("[MLLP.Connection] Pipeline not found for channel #{channel_id}")
    end
  end

  defp generate_control_id do
    :crypto.strong_rand_bytes(6) |> Base.encode16()
  end

  # Returns :ok if the peer IP is permitted, {:rejected, ip_string} otherwise.
  # An empty allowlist means accept from any IP.
  defp check_peer_ip(_socket, [], _transport), do: :ok

  defp check_peer_ip(socket, allowed_ips, transport) do
    peername_fn = case transport do
      :ssl -> &:ssl.peername/1
      :gen_tcp -> &:inet.peername/1
    end

    case peername_fn.(socket) do
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

  defp set_active(socket, :gen_tcp), do: :inet.setopts(socket, active: true)
  defp set_active(socket, :ssl), do: :ssl.setopts(socket, active: true)

  defp close(socket, :gen_tcp), do: :gen_tcp.close(socket)
  defp close(socket, :ssl), do: :ssl.close(socket)

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
