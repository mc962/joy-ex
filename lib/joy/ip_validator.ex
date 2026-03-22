defmodule Joy.IPValidator do
  @moduledoc """
  Shared IP/CIDR validation used by Channel and Organization changesets.

  # GO-TRANSLATION:
  # net.ParseIP / net.ParseCIDR equivalents. Elixir uses :inet.parse_address/1.
  """

  @doc "Returns true if the string is a valid plain IP or CIDR block."
  def valid_ip_or_cidr?(entry) do
    case String.split(entry, "/", parts: 2) do
      [ip] ->
        match?({:ok, _}, :inet.parse_address(to_charlist(ip)))

      [ip, prefix] ->
        match?({:ok, _}, :inet.parse_address(to_charlist(ip))) and
          match?({n, ""} when n in 0..32, Integer.parse(prefix))
    end
  end

  @doc "Changeset validator for an {:array, :string} allowed_ips field."
  def validate_allowed_ips(changeset, field \\ :allowed_ips) do
    import Ecto.Changeset
    validate_change(changeset, field, fn ^field, ips ->
      invalid = Enum.reject(ips, &valid_ip_or_cidr?/1)
      if invalid == [],
        do: [],
        else: [{field, "contains invalid entries: #{Enum.join(invalid, ", ")}"}]
    end)
  end
end
