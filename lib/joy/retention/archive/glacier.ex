defmodule Joy.Retention.Archive.Glacier do
  @moduledoc """
  Archive backend: AWS S3 Glacier (GLACIER storage class).

  Identical to the S3 backend but uploads with `x-amz-storage-class: GLACIER`,
  placing objects in the Glacier retrieval tier (3-5 hour restore time).
  Uses the same bucket/prefix/credentials config as the S3 backend.

  This uses the modern S3-compatible Glacier API (not the legacy Vault API),
  which allows objects to be managed with normal S3 tooling while benefiting
  from Glacier's long-term archival pricing.

  # GO-TRANSLATION:
  # s3.PutObjectInput with StorageClass: s3types.StorageClassGlacier
  """

  @behaviour Joy.Retention.Archive

  require Logger

  @impl true
  def store(data, filename, settings) do
    key = prefix(settings) <> filename

    ExAws.S3.put_object(settings.aws_bucket, key, data,
      content_type: "application/gzip",
      content_encoding: "gzip",
      storage_class: "GLACIER"
    )
    |> ExAws.request(Joy.Retention.Archive.S3.aws_config(settings))
    |> case do
      {:ok, _} ->
        Logger.info("[Retention.Archive.Glacier] Archived to s3://#{settings.aws_bucket}/#{key} (GLACIER)")
        :ok

      {:error, reason} ->
        Logger.error("[Retention.Archive.Glacier] Upload failed for #{key}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp prefix(%{aws_prefix: p}) when is_binary(p) and p != "", do: p
  defp prefix(_), do: "joy-archive/"
end
