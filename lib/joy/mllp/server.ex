defmodule Joy.MLLP.Server do
  @moduledoc """
  MLLP TCP listener for a single channel. Accepts connections and hands them
  off to Joy.MLLP.Connection via Joy.MLLP.ConnectionSupervisor.

  Why GenServer: OTP supervision, clean shutdown via terminate/2, introspection.
  The blocking `:gen_tcp.accept/1` call runs in a spawned acceptor process so
  it doesn't block the GenServer's message loop.

  # GO-TRANSLATION:
  # net.Listen() + for { conn, _ := ln.Accept(); go handleConn(conn) }
  # OTP supervision restarts the server on crash; Go needs manual retry logic.
  """

  use GenServer
  require Logger

  def start_link(%{id: _, mllp_port: _} = channel) do
    GenServer.start_link(__MODULE__, channel, name: via(channel.id))
  end

  def child_spec(%{id: id} = channel) do
    %{
      id: {__MODULE__, id},
      start: {__MODULE__, :start_link, [channel]},
      restart: :permanent,
      type: :worker
    }
  end

  @impl true
  def init(%{id: channel_id, mllp_port: port} = _channel) do
    case :gen_tcp.listen(port, [:binary, packet: :raw, active: false, reuseaddr: true, ip: {0, 0, 0, 0}]) do
      {:ok, socket} ->
        state = %{channel_id: channel_id, port: port, listen_socket: socket, acceptor: nil}
        {:ok, start_acceptor(state)}

      {:error, reason} ->
        Logger.error("[MLLP.Server] Failed to listen on port #{port}: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl true
  def handle_info({:acceptor_down, pid, reason}, %{acceptor: pid} = state) when reason != :normal do
    Logger.warning("[MLLP.Server] Acceptor crashed (#{inspect(reason)}), restarting")
    {:noreply, start_acceptor(state)}
  end
  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{listen_socket: socket}) do
    :gen_tcp.close(socket)
  end

  defp start_acceptor(%{listen_socket: socket, channel_id: channel_id} = state) do
    parent = self()
    pid = spawn_link(fn -> accept_loop(socket, channel_id, parent) end)
    %{state | acceptor: pid}
  end

  defp accept_loop(socket, channel_id, parent) do
    case :gen_tcp.accept(socket) do
      {:ok, client} ->
        spec = {Joy.MLLP.Connection, {channel_id, client}}
        case DynamicSupervisor.start_child(Joy.MLLP.ConnectionSupervisor, spec) do
          {:ok, pid} ->
            :gen_tcp.controlling_process(client, pid)
          {:error, :normal} ->
            # Connection was rejected cleanly (e.g. IP not in allowlist) — already logged and closed.
            :ok
          {:error, reason} ->
            Logger.error("[MLLP.Server] Failed to start connection: #{inspect(reason)}")
            :gen_tcp.close(client)
        end
        accept_loop(socket, channel_id, parent)

      {:error, :closed} ->
        # Server shutting down — acceptor exits cleanly
        :ok

      {:error, reason} ->
        Logger.warning("[MLLP.Server] accept error: #{inspect(reason)}, retrying")
        accept_loop(socket, channel_id, parent)
    end
  end

  defp via(channel_id), do: {:via, Horde.Registry, {Joy.ChannelRegistry, {:mllp_server, channel_id}}}
end
