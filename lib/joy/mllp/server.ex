defmodule Joy.MLLP.Server do
  @moduledoc """
  MLLP TCP (or TLS) listener for a single channel, backed by ThousandIsland.

  ThousandIsland manages the acceptor pool, TLS handshake concurrency, and
  per-connection process supervision internally. Joy.MLLP.Connection is the
  handler module — ThousandIsland spawns one handler process per accepted
  connection and calls its callbacks.

  `num_acceptors: 100` — ThousandIsland default; 100 acceptors can handle
  100 simultaneous TLS handshakes without queueing. Explicit here for clarity.

  Dev/test tip: generate a self-signed cert with:
    mix phx.gen.cert
  This produces priv/cert.pem and priv/key.pem which can be pasted into the TLS
  config form. The MLLP client tools use verify: :verify_none so they connect
  to self-signed certs without issue.

  # GO-TRANSLATION:
  # net.Listen() + for { conn, _ := ln.Accept(); go handleConn(conn) }
  # ThousandIsland is the Elixir equivalent of a Go TCP server with a goroutine
  # pool — no manual acceptor management needed.
  """

  def start_link(%{id: _, mllp_port: _} = channel) do
    ThousandIsland.start_link(thousand_island_opts(channel))
  end

  def child_spec(%{id: id} = channel) do
    %{
      id: {__MODULE__, id},
      start: {__MODULE__, :start_link, [channel]},
      type: :supervisor,
      restart: :permanent
    }
  end

  defp thousand_island_opts(channel) do
    {transport_module, transport_options} = transport_config(channel)
    [
      port: channel.mllp_port,
      handler_module: Joy.MLLP.Connection,
      handler_options: %{channel_id: channel.id},
      transport_module: transport_module,
      transport_options: transport_options,
      num_acceptors: 100
    ]
  end

  defp transport_config(%{tls_enabled: false}) do
    {ThousandIsland.Transports.TCP, [reuseaddr: true, backlog: 128]}
  end

  defp transport_config(%{tls_enabled: true} = channel) do
    [{:Certificate, cert_der, _} | _] = :public_key.pem_decode(channel.tls_cert_pem)
    [{key_type, key_der, _} | _] = :public_key.pem_decode(channel.tls_key_pem)

    tls_opts = [
      cert:    cert_der,
      key:     {key_type, key_der},
      verify:  if(channel.tls_verify_peer, do: :verify_peer, else: :verify_none),
      reuseaddr: true,
      backlog: 128
    ]

    tls_opts =
      if channel.tls_ca_cert_pem && channel.tls_ca_cert_pem != "" do
        ca_certs = for {:Certificate, der, _} <- :public_key.pem_decode(channel.tls_ca_cert_pem), do: der
        [{:cacerts, ca_certs} | tls_opts]
      else
        tls_opts
      end

    {ThousandIsland.Transports.SSL, tls_opts}
  end
end
