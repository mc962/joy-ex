defmodule Joy.Encrypted.MapType do
  @moduledoc """
  Custom Ecto type: transparently encrypts a map field as an AES-256-GCM binary blob.

  Write path: map → JSON → encrypt → binary
  Read path:  binary → decrypt → JSON → map

  Used for destination_configs.config to protect adapter credentials at rest.

  # GO-TRANSLATION:
  # Implement database/sql Scanner + Valuer interfaces on a wrapper struct.
  # func (m *EncryptedMap) Scan(v any) error { /* decrypt */ }
  # func (m EncryptedMap) Value() (driver.Value, error) { /* encrypt */ }
  """

  use Ecto.Type

  @impl true
  def type, do: :binary

  @impl true
  def cast(v) when is_map(v), do: {:ok, v}
  def cast(v) when is_list(v) do
    if Keyword.keyword?(v),
      do: {:ok, Map.new(v, fn {k, val} -> {to_string(k), val} end)},
      else: :error
  end
  def cast(_), do: :error

  @impl true
  def dump(map) when is_map(map) do
    try do
      {:ok, map |> Jason.encode!() |> Joy.Crypto.encrypt()}
    rescue
      _ -> :error
    end
  end
  def dump(_), do: :error

  @impl true
  def load(binary) when is_binary(binary) do
    with {:ok, json} <- Joy.Crypto.decrypt(binary),
         {:ok, map} <- Jason.decode(json),
         do: {:ok, map},
         else: (_ -> :error)
  end
  def load(_), do: :error

  @impl true
  def equal?(a, b), do: a == b
end
