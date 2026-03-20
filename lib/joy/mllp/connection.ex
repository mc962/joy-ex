defmodule Joy.MLLP.Connection do
  @moduledoc """
  Handles a single MLLP TCP client connection.

  Message flow (guaranteeing at-least-once delivery):
    1. Receive TCP data, buffer partial frames
    2. Extract complete MLLP frames via Joy.MLLP.Framer.unwrap/1
    3. Parse HL7 with Joy.HL7.Parser
    4. Persist to message_log as :pending BEFORE ACKing
    5. Send ACK (AA on success, AE on error)
    6. Dispatch to Joy.Channel.Pipeline async

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
  require Logger

  def start_link({channel_id, socket}) do
    GenServer.start_link(__MODULE__, {channel_id, socket})
  end

  def child_spec({channel_id, socket}) do
    %{
      id: {__MODULE__, :erlang.unique_integer()},
      start: {__MODULE__, :start_link, [{channel_id, socket}]},
      restart: :temporary,
      type: :worker
    }
  end

  @impl true
  def init({channel_id, socket}) do
    # Set active: true so TCP data arrives as messages to this process
    :inet.setopts(socket, active: true)
    {:ok, %{channel_id: channel_id, socket: socket, buffer: ""}}
  end

  @impl true
  def handle_info({:tcp, _socket, data}, state) do
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
            send_ack(state.socket, msg, :aa)

          {:ok, entry} ->
            send_ack(state.socket, msg, :aa)
            dispatch_to_pipeline(state.channel_id, entry.id)

          {:error, reason} ->
            Logger.error("[MLLP.Connection] Failed to persist message: #{inspect(reason)}")
            send_ack(state.socket, msg, :ae)
        end

      {:error, reason} ->
        Logger.error("[MLLP.Connection] Failed to parse HL7: #{inspect(reason)}")
        # Build a minimal ACK from raw data
        :gen_tcp.send(state.socket, minimal_ae_ack())
    end
  end

  defp send_ack(socket, msg, code) do
    ack = Joy.MLLP.Framer.build_ack(msg, code)
    :gen_tcp.send(socket, ack)
  end

  defp dispatch_to_pipeline(channel_id, entry_id) do
    case Registry.lookup(Joy.ChannelRegistry, {:pipeline, channel_id}) do
      [{pid, _}] -> GenServer.cast(pid, {:process, entry_id})
      [] -> Logger.warning("[MLLP.Connection] Pipeline not found for channel #{channel_id}")
    end
  end

  defp generate_control_id do
    :crypto.strong_rand_bytes(6) |> Base.encode16()
  end

  defp minimal_ae_ack do
    msg = "MSH|^~\\&|Joy|||||||#{DateTime.utc_now() |> Calendar.strftime("%Y%m%d%H%M%S")}||ACK|#{generate_control_id()}|P|2.5\rMSA|AE|\r"
    Joy.MLLP.Framer.wrap(msg)
  end
end
