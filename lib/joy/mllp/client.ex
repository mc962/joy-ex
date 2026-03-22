defmodule Joy.MLLP.Client do
  @moduledoc """
  Stateless MLLP test client. Opens a TCP (or TLS) connection, sends a framed
  HL7 message, reads the ACK, closes the socket, and returns timing info.

  Designed for use by the MLLP Client UI tool — not for production pipeline use
  (the pipeline uses Joy.Destinations.Adapters.MllpForward).

  TLS option: pass `tls: true` in opts to connect with SSL. Uses verify: :verify_none
  so self-signed and internally-issued certs work without installing them in the OS
  trust store — appropriate for the test client tool.

  # GO-TRANSLATION: net.DialTimeout / tls.DialWithDialer + conn.Write/Read + defer conn.Close()
  # Same structure; latency captured with time.Now() / time.Since().
  """

  @default_timeout 10_000

  @doc """
  Send an HL7 message to an MLLP endpoint and return the ACK with latency.

  Options:
    - `:timeout_ms`   — TCP connect/recv timeout in ms (default 10_000)
    - `:tls`          — connect with TLS (default false)
    - `:tls_verify`   — verify the server's certificate when using TLS (default true)
  """
  @spec send_message(String.t(), pos_integer(), String.t(), keyword()) ::
          {:ok, %{ack_raw: String.t(), ack_code: String.t(), latency_ms: non_neg_integer()}}
          | {:error, term()}
  def send_message(host, port, hl7_string, opts \\ []) do
    timeout    = Keyword.get(opts, :timeout_ms, @default_timeout)
    tls        = Keyword.get(opts, :tls, false)
    tls_verify = Keyword.get(opts, :tls_verify, true)

    with_socket(host, port, timeout, tls, tls_verify, fn socket, transport ->
      t0 = System.monotonic_time(:millisecond)

      with :ok <- transport.send(socket, Joy.MLLP.Framer.wrap(hl7_string)),
           {:ok, ack_data} <- transport.recv(socket, 0, timeout) do
        t1 = System.monotonic_time(:millisecond)
        latency_ms = t1 - t0

        ack_code =
          case Joy.MLLP.Framer.unwrap(ack_data) do
            {:ok, ack_hl7, _} ->
              case Joy.HL7.Parser.parse(ack_hl7) do
                {:ok, ack_msg} -> Joy.HL7.get(ack_msg, "MSA.1") || "??"
                _ -> "??"
              end
            _ ->
              "??"
          end

        ack_raw =
          case Joy.MLLP.Framer.unwrap(ack_data) do
            {:ok, text, _} -> text
            _ -> ack_data
          end

        {:ok, %{ack_raw: ack_raw, ack_code: ack_code, latency_ms: latency_ms}}
      end
    end)
  end

  # Opens a plain TCP socket.
  defp with_socket(host, port, timeout, false, _tls_verify, fun) do
    charlist_host = String.to_charlist(host)
    case :gen_tcp.connect(charlist_host, port, [:binary, packet: :raw, active: false], timeout) do
      {:ok, socket} ->
        result = fun.(socket, :gen_tcp)
        :gen_tcp.close(socket)
        result
      {:error, reason} ->
        {:error, reason}
    end
  end

  # Opens a TLS socket. tls_verify: true uses :verify_peer (default, secure).
  # tls_verify: false uses :verify_none for self-signed / internal CA certs in dev.
  defp with_socket(host, port, timeout, true, tls_verify, fun) do
    charlist_host = String.to_charlist(host)
    verify = if tls_verify, do: :verify_peer, else: :verify_none
    ssl_opts = [:binary, packet: :raw, active: false, verify: verify]
    case :ssl.connect(charlist_host, port, ssl_opts, timeout) do
      {:ok, socket} ->
        result = fun.(socket, :ssl)
        :ssl.close(socket)
        result
      {:error, reason} ->
        {:error, reason}
    end
  end
end
