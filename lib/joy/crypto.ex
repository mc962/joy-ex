defmodule Joy.Crypto do
  @moduledoc """
  AES-256-GCM encryption for secrets stored in the database (destination credentials).
  Uses authenticated encryption — tampered ciphertext is detected on decryption.

  Why AES-256-GCM: authenticated, no external deps (uses built-in `:crypto`),
  industry standard for secrets at rest in healthcare contexts.

  Wire format: <<iv::12-bytes, tag::16-bytes, ciphertext::binary>>

  # GO-TRANSLATION:
  # Go: crypto/aes + cipher.NewGCM(). gcm.Seal(nonce, nonce, plaintext, aad) to encrypt.
  # gcm.Open(nil, nonce, ciphertext, aad) to decrypt. Nearly identical logic;
  # Go returns ([]byte, error) where Elixir pattern-matches.
  """

  @aad "joy_hl7_engine_v1"

  @doc "Encrypt plaintext. Returns iv <> tag <> ciphertext binary."
  @spec encrypt(binary()) :: binary()
  def encrypt(plaintext) when is_binary(plaintext) do
    iv = :crypto.strong_rand_bytes(12)
    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key(), iv, plaintext, @aad, true)
    iv <> tag <> ciphertext
  end

  @doc "Decrypt a blob produced by encrypt/1."
  @spec decrypt(binary()) :: {:ok, binary()} | {:error, :decryption_failed}
  def decrypt(<<iv::binary-12, tag::binary-16, ciphertext::binary>>) do
    case :crypto.crypto_one_time_aead(:aes_256_gcm, key(), iv, ciphertext, @aad, tag, false) do
      plaintext when is_binary(plaintext) -> {:ok, plaintext}
      _ -> {:error, :decryption_failed}
    end
  end
  def decrypt(_), do: {:error, :decryption_failed}

  defp key, do: Application.fetch_env!(:joy, :encryption_key) |> Base.decode64!()
end
