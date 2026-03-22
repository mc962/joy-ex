defmodule Joy.CertParser do
  @moduledoc """
  Parses X.509 PEM certificates and extracts human-readable metadata.

  Uses Erlang's :public_key module — no external dependencies.

  Returns CN, issuer CN, SANs, and expiry as a DateTime. Used to:
    - Display cert info in the channel TLS config UI
    - Populate tls_cert_expires_at for expiry monitoring

  # GO-TRANSLATION:
  # x509.ParseCertificate(der) + cert.Subject.CommonName / cert.DNSNames /
  # cert.NotAfter. Erlang's :public_key returns Erlang record tuples where Go
  # returns struct fields — same data, different shape.
  """

  @cn_oid {2, 5, 4, 3}
  @san_oid {2, 5, 29, 17}

  @doc """
  Parse a PEM string containing at least one X.509 certificate.
  Returns {:ok, %{cn:, issuer:, sans:, expires_at:}} or {:error, reason}.
  """
  @spec parse(binary() | nil) :: {:ok, map()} | {:error, term()}
  def parse(nil), do: {:error, :no_cert}
  def parse(""), do: {:error, :no_cert}
  def parse(pem) when is_binary(pem) do
    case :public_key.pem_decode(pem) do
      [{:Certificate, der, _} | _] ->
        try do
          {:OTPCertificate, tbs, _, _} = :public_key.pkix_decode_cert(der, :otp)

          {:OTPTBSCertificate, _version, _serial, _sig_alg, issuer_rdn,
           validity, subject_rdn, _spki, _iuid, _suid, extensions} = tbs

          {:Validity, _not_before, not_after} = validity

          {:ok, %{
            expires_at: parse_time(not_after),
            cn:         extract_cn(subject_rdn),
            issuer:     extract_cn(issuer_rdn),
            sans:       extract_sans(extensions)
          }}
        rescue
          e -> {:error, {:parse_error, Exception.message(e)}}
        end

      [] ->
        {:error, :no_certificate_in_pem}

      _ ->
        {:error, :no_certificate_in_pem}
    end
  end

  @doc """
  Returns the number of days until the cert expires (negative = already expired).
  """
  @spec days_until_expiry(binary()) :: {:ok, integer()} | {:error, term()}
  def days_until_expiry(pem) do
    case parse(pem) do
      {:ok, %{expires_at: dt}} ->
        {:ok, DateTime.diff(dt, DateTime.utc_now(), :day)}
      err ->
        err
    end
  end

  # ---------- private ----------

  # UTCTime format: "YYMMDDHHMMSSZ"
  defp parse_time({:utcTime, chars}) do
    s = to_string(chars)
    <<yy::binary-2, mm::binary-2, dd::binary-2, hh::binary-2, mi::binary-2, ss::binary-2, _::binary>> = s
    yr = String.to_integer(yy)
    # X.509 rule: 00-49 = 2000s, 50-99 = 1900s
    year = if yr >= 50, do: 1900 + yr, else: 2000 + yr
    {:ok, dt, 0} = DateTime.from_iso8601("#{year}-#{mm}-#{dd}T#{hh}:#{mi}:#{ss}Z")
    dt
  end

  # GeneralizedTime format: "YYYYMMDDHHMMSSZ"
  defp parse_time({:generalTime, chars}) do
    s = to_string(chars)
    <<yyyy::binary-4, mm::binary-2, dd::binary-2, hh::binary-2, mi::binary-2, ss::binary-2, _::binary>> = s
    {:ok, dt, 0} = DateTime.from_iso8601("#{yyyy}-#{mm}-#{dd}T#{hh}:#{mi}:#{ss}Z")
    dt
  end

  # rdnSequence is a list of lists of AttributeTypeAndValue tuples
  defp extract_cn({:rdnSequence, rdns}) do
    rdns
    |> List.flatten()
    |> Enum.find_value(fn
      {:AttributeTypeAndValue, @cn_oid, value} -> string_value(value)
      _ -> nil
    end)
  end
  defp extract_cn(_), do: nil

  defp string_value({:utf8String, v}), do: to_string(v)
  defp string_value({:printableString, v}), do: to_string(v)
  defp string_value({:ia5String, v}), do: to_string(v)
  defp string_value(v) when is_binary(v), do: v
  defp string_value(v) when is_list(v), do: to_string(v)
  defp string_value(_), do: nil

  # In OTP mode, extension values are already decoded by :public_key
  defp extract_sans(:asn1_NOVALUE), do: []
  defp extract_sans(extensions) when is_list(extensions) do
    case Enum.find(extensions, fn {:Extension, oid, _, _} -> oid == @san_oid end) do
      nil ->
        []
      {:Extension, _, _, value} ->
        try do
          names = if is_list(value), do: value, else: :public_key.der_decode(:SubjectAltName, value)
          Enum.flat_map(names, fn
            {:dNSName, name} -> [to_string(name)]
            {:iPAddress, bytes} when is_list(bytes) and length(bytes) == 4 ->
              [Enum.join(bytes, ".")]
            {:iPAddress, bytes} when is_binary(bytes) and byte_size(bytes) == 4 ->
              <<a, b, c, d>> = bytes
              ["#{a}.#{b}.#{c}.#{d}"]
            _ ->
              []
          end)
        rescue
          _ -> []
        end
    end
  end
  defp extract_sans(_), do: []
end
