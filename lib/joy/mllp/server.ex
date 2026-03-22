defmodule Joy.MLLP.Server do
  @moduledoc """
  MLLP TCP (or TLS) listener for a single channel. Accepts connections and hands them
  off to Joy.MLLP.Connection via Joy.MLLP.ConnectionSupervisor.

  When channel.tls_enabled is true, uses :ssl instead of :gen_tcp:
    - :ssl.listen/2 with certfile, keyfile, optional cacertfile + verify_peer
    - :ssl.transport_accept/1 + :ssl.handshake/1 in the acceptor loop
    - Passes transport type to Joy.MLLP.Connection so it uses ssl.*() calls

  Dev/test tip: generate a self-signed cert with:
    mix phx.gen.cert
  This produces priv/cert.pem and priv/key.pem which can be pasted into the TLS
  config form. The MLLP client tools use verify: :verify_none so they connect
  to self-signed certs without issue.

  # GO-TRANSLATION:
  # net.Listen() + for { conn, _ := ln.Accept(); go handleConn(conn) }
  # OTP supervision restarts the server on crash; Go needs manual retry logic.
  # For TLS: tls.NewListener(net.Listen("tcp", addr), &tls.Config{...})
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
  def init(%{id: channel_id, mllp_port: port} = channel) do
    transport = if channel.tls_enabled, do: :ssl, else: :gen_tcp
    opts = listen_opts(channel)

    case transport.listen(port, opts) do
      {:ok, socket} ->
        state = %{
          channel_id: channel_id,
          port: port,
          listen_socket: socket,
          acceptor: nil,
          transport: transport
        }
        {:ok, start_acceptor(state)}

      {:error, reason} ->
        Logger.error("[MLLP.Server] Failed to listen on port #{port} (transport: #{transport}): #{inspect(reason)}")
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
  def terminate(_reason, %{listen_socket: socket, transport: transport}) do
    transport.close(socket)
  end

  defp start_acceptor(%{listen_socket: socket, channel_id: channel_id, transport: transport} = state) do
    parent = self()
    pid = spawn_link(fn -> accept_loop(socket, channel_id, transport, parent) end)
    %{state | acceptor: pid}
  end

  defp accept_loop(socket, channel_id, :gen_tcp = transport, parent) do
    case :gen_tcp.accept(socket) do
      {:ok, client} ->
        start_connection(channel_id, client, transport)
        accept_loop(socket, channel_id, transport, parent)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        Logger.warning("[MLLP.Server] accept error: #{inspect(reason)}, retrying")
        accept_loop(socket, channel_id, transport, parent)
    end
  end

  defp accept_loop(socket, channel_id, :ssl = transport, parent) do
    # For TLS: first accept the TCP connection, then negotiate TLS handshake.
    # transport_accept/1 is the blocking call; handshake/1 completes the SSL negotiation.
    case :ssl.transport_accept(socket) do
      {:ok, tls_transport_socket} ->
        case :ssl.handshake(tls_transport_socket) do
          {:ok, ssl_socket} ->
            start_connection(channel_id, ssl_socket, transport)

          {:error, reason} ->
            Logger.warning("[MLLP.Server] TLS handshake failed: #{inspect(reason)}")
            # ssl auto-closes tls_transport_socket on handshake failure
        end
        accept_loop(socket, channel_id, transport, parent)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        Logger.warning("[MLLP.Server] SSL transport_accept error: #{inspect(reason)}, retrying")
        accept_loop(socket, channel_id, transport, parent)
    end
  end

  defp start_connection(channel_id, client, transport) do
    spec = {Joy.MLLP.Connection, {channel_id, client, transport}}
    case DynamicSupervisor.start_child(Joy.MLLP.ConnectionSupervisor, spec) do
      {:ok, pid} ->
        controlling_process(client, pid, transport)
      {:error, :normal} ->
        # Connection was rejected cleanly (e.g. IP not in allowlist) — already logged and closed.
        :ok
      {:error, reason} ->
        Logger.error("[MLLP.Server] Failed to start connection: #{inspect(reason)}")
        transport.close(client)
    end
  end

  defp controlling_process(socket, pid, :gen_tcp), do: :gen_tcp.controlling_process(socket, pid)
  defp controlling_process(socket, pid, :ssl), do: :ssl.controlling_process(socket, pid)

  # Common TCP options shared by both plain and TLS listeners.
  defp base_opts do
    [:binary, packet: :raw, active: false, reuseaddr: true, ip: {0, 0, 0, 0}]
  end

  defp listen_opts(%{tls_enabled: false}), do: base_opts()
  defp listen_opts(%{tls_enabled: true} = channel) do
    # Decode PEM content to DER binaries for :ssl.listen/2.
    # :ssl accepts :cert (DER binary) and :key ({type, DER}) instead of file paths,
    # which lets us store cert material in the DB without any filesystem dependency.
    [{:Certificate, cert_der, _} | _] = :public_key.pem_decode(channel.tls_cert_pem)
    [{key_type, key_der, _} | _] = :public_key.pem_decode(channel.tls_key_pem)

    tls_opts = [
      cert:   cert_der,
      key:    {key_type, key_der},
      verify: if(channel.tls_verify_peer, do: :verify_peer, else: :verify_none)
    ]

    tls_opts =
      if channel.tls_ca_cert_pem && channel.tls_ca_cert_pem != "" do
        ca_certs = for {:Certificate, der, _} <- :public_key.pem_decode(channel.tls_ca_cert_pem), do: der
        [{:cacerts, ca_certs} | tls_opts]
      else
        tls_opts
      end

    base_opts() ++ tls_opts
  end

  defp via(channel_id), do: {:via, Horde.Registry, {Joy.ChannelRegistry, {:mllp_server, channel_id}}}
end
