defmodule Joy.Encrypted.StringType do
  @moduledoc """
  Custom Ecto type: encrypts a string field as an AES-256-GCM binary blob.

  Used for tls_key_pem — the private key must be encrypted at rest.
  Cert and CA cert PEM fields are not sensitive (public data) and use plain :string.

  # GO-TRANSLATION:
  # Implement database/sql Scanner + Valuer interfaces on a wrapper struct,
  # same pattern as Encrypted.MapType but for raw strings instead of JSON maps.
  """

  use Ecto.Type

  @impl true
  def type, do: :binary

  @impl true
  def cast(nil), do: {:ok, nil}
  def cast(v) when is_binary(v), do: {:ok, v}
  def cast(_), do: :error

  @impl true
  def dump(nil), do: {:ok, nil}
  def dump(v) when is_binary(v) do
    try do
      {:ok, Joy.Crypto.encrypt(v)}
    rescue
      _ -> :error
    end
  end
  def dump(_), do: :error

  @impl true
  def load(nil), do: {:ok, nil}
  def load(v) when is_binary(v) do
    case Joy.Crypto.decrypt(v) do
      {:ok, plaintext} -> {:ok, plaintext}
      {:error, _} -> :error
    end
  end
  def load(_), do: :error

  @impl true
  def equal?(a, b), do: a == b
end
