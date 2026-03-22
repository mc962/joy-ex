defmodule Joy.Retention.Archive do
  @moduledoc """
  Behaviour for message log archive backends.

  Implementors receive gzip-compressed NDJSON data (one JSON object per line,
  one line per message log entry) and a filename, and are responsible for
  persisting it to their respective storage system.

  The filename includes a UTC timestamp and chunk index so multiple archive
  files from the same purge run are distinguishable.

  # GO-TRANSLATION:
  # io.Writer interface; each backend wraps an upload client and writes to it.
  """

  @doc """
  Store `data` (gzip binary) under `filename` using the given settings struct.
  Returns `:ok` on success or `{:error, reason}` on failure.
  On failure, `Joy.Retention.run_purge/1` aborts before deleting entries.
  """
  @callback store(data :: binary(), filename :: String.t(), settings :: Joy.Retention.Settings.t()) ::
              :ok | {:error, term()}

  @doc "Resolve the archive module for a given destination string."
  def for_destination("local_fs"), do: Joy.Retention.Archive.LocalFS
  def for_destination("s3"), do: Joy.Retention.Archive.S3
  def for_destination("glacier"), do: Joy.Retention.Archive.Glacier
end
