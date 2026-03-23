defmodule Mix.Tasks.Joy.RotateKey do
  @shortdoc "Re-encrypts all secrets from --old-key to --new-key"
  @moduledoc """
  Usage: mix joy.rotate_key --old-key OLD_B64 --new-key NEW_B64 [--batch-size N]

  Re-encrypts every encrypted field in the database from the old AES-256-GCM key
  to the new one. Processes rows in cursor-based batches (default 100), each in
  its own short transaction. Aborts before touching the DB if the old key can't
  decrypt an existing value (pre-flight check).

  Rotation workflow:
    1. Generate a new key:
         mix run -e ':crypto.strong_rand_bytes(32) |> Base.encode64() |> IO.puts()'
    2. Set ENCRYPTION_KEY_OLD=<current key>, ENCRYPTION_KEY=<new key>
    3. Deploy the new release (dual-read fallback covers the rollout window)
    4. Run: mix joy.rotate_key --old-key <old> --new-key <new>
    5. Remove ENCRYPTION_KEY_OLD from the environment
  """

  use Mix.Task

  @requirements ["app.start"]
  @default_batch_size 100

  @tables_cols [
    {"channels", "tls_key_pem"},
    {"destination_configs", "config"},
    {"retention_settings", "aws_access_key_id"},
    {"retention_settings", "aws_secret_access_key"}
  ]

  @aad "joy_hl7_engine_v1"

  @impl true
  def run(args) do
    {opts, _} =
      OptionParser.parse!(args,
        strict: [old_key: :string, new_key: :string, batch_size: :integer])

    old_b64 = opts[:old_key] || Mix.raise("--old-key is required")
    new_b64 = opts[:new_key] || Mix.raise("--new-key is required")
    batch_size = opts[:batch_size] || @default_batch_size

    old_key = decode_key!(old_b64, "--old-key")
    new_key = decode_key!(new_b64, "--new-key")

    preflight!(old_key)

    total =
      Enum.reduce(@tables_cols, 0, fn {table, col}, acc ->
        acc + rotate_column(table, col, old_key, new_key, batch_size)
      end)

    Mix.shell().info("Key rotation complete. #{total} value(s) re-encrypted.")
  end

  # --- private ---

  defp decode_key!(b64, flag) do
    bytes = Base.decode64!(b64)
    if byte_size(bytes) != 32, do: Mix.raise("#{flag} must decode to exactly 32 bytes")
    bytes
  rescue
    _ -> Mix.raise("#{flag} is not valid base64")
  end

  defp preflight!(old_key) do
    Mix.shell().info("Running pre-flight check...")

    Enum.each(@tables_cols, fn {table, col} ->
      %{rows: rows} =
        Joy.Repo.query!(
          "SELECT #{col} FROM #{table} WHERE #{col} IS NOT NULL LIMIT 1",
          []
        )

      case rows do
        [] ->
          :ok

        [[blob]] ->
          case decrypt_with(blob, old_key) do
            {:ok, _} ->
              :ok

            {:error, _} ->
              Mix.raise(
                "Pre-flight failed: --old-key cannot decrypt #{table}.#{col}. " <>
                  "Wrong key, or already rotated."
              )
          end
      end
    end)

    Mix.shell().info("Pre-flight passed.")
  end

  defp rotate_column(table, col, old_key, new_key, batch_size) do
    rotate_batch(table, col, old_key, new_key, batch_size, _last_id = 0, _total = 0)
  end

  defp rotate_batch(table, col, old_key, new_key, batch_size, last_id, total) do
    %{rows: rows} =
      Joy.Repo.query!(
        "SELECT id, #{col} FROM #{table} " <>
          "WHERE #{col} IS NOT NULL AND id > $1 ORDER BY id LIMIT $2",
        [last_id, batch_size]
      )

    case rows do
      [] ->
        Mix.shell().info("  #{table}.#{col}: #{total} row(s) rotated")
        total

      _ ->
        batch_count = length(rows)

        {:ok, _} =
          Joy.Repo.transaction(fn ->
            Enum.each(rows, fn [id, blob] ->
              {:ok, plaintext} = decrypt_with(blob, old_key)

              Joy.Repo.query!(
                "UPDATE #{table} SET #{col} = $1 WHERE id = $2",
                [encrypt_with(plaintext, new_key), id]
              )
            end)
          end)

        last_id = rows |> List.last() |> hd()
        rotate_batch(table, col, old_key, new_key, batch_size, last_id, total + batch_count)
    end
  end

  defp decrypt_with(<<iv::binary-12, tag::binary-16, ct::binary>>, key) do
    case :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, ct, @aad, tag, false) do
      pt when is_binary(pt) -> {:ok, pt}
      _ -> {:error, :decryption_failed}
    end
  end

  defp decrypt_with(_, _), do: {:error, :decryption_failed}

  defp encrypt_with(plaintext, key) do
    iv = :crypto.strong_rand_bytes(12)
    {ct, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, plaintext, @aad, true)
    iv <> tag <> ct
  end
end
