defmodule Joy.Retention.Archive.S3 do
  @moduledoc """
  Archive backend: AWS S3 (STANDARD storage class).

  Uploads gzip-compressed NDJSON to `{aws_bucket}/{aws_prefix}{filename}`.
  The prefix defaults to "joy-archive/" when not set.

  Leave aws_access_key_id blank to use IAM instance roles (preferred in EC2/ECS).

  # GO-TRANSLATION:
  # s3.PutObjectInput with Body = bytes.NewReader(data)
  """

  @behaviour Joy.Retention.Archive

  require Logger

  @impl true
  def store(data, filename, settings) do
    key = prefix(settings) <> filename

    ExAws.S3.put_object(settings.aws_bucket, key, data,
      content_type: "application/gzip",
      content_encoding: "gzip"
    )
    |> ExAws.request(aws_config(settings))
    |> case do
      {:ok, _} ->
        Logger.info("[Retention.Archive.S3] Archived to s3://#{settings.aws_bucket}/#{key}")
        :ok

      {:error, reason} ->
        Logger.error("[Retention.Archive.S3] Upload failed for #{key}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp prefix(%{aws_prefix: p}) when is_binary(p) and p != "", do: p
  defp prefix(_), do: "joy-archive/"

  def aws_config(settings) do
    base = [region: settings.aws_region]

    if is_binary(settings.aws_access_key_id) and settings.aws_access_key_id != "" do
      base ++
        [access_key_id: settings.aws_access_key_id,
         secret_access_key: settings.aws_secret_access_key]
    else
      base
    end
  end
end
