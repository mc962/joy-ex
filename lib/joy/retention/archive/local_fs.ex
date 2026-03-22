defmodule Joy.Retention.Archive.LocalFS do
  @moduledoc """
  Archive backend: local filesystem.

  Writes gzip-compressed NDJSON archive files to `settings.local_path`.
  The directory is created if it does not exist.

  # GO-TRANSLATION:
  # os.MkdirAll + os.WriteFile
  """

  @behaviour Joy.Retention.Archive

  require Logger

  @impl true
  def store(data, filename, %{local_path: path}) when is_binary(path) and path != "" do
    full_path = Path.join(path, filename)

    with :ok <- File.mkdir_p(path),
         :ok <- File.write(full_path, data) do
      Logger.info("[Retention.Archive.LocalFS] Archived #{byte_size(data)} bytes to #{full_path}")
      :ok
    else
      {:error, reason} ->
        Logger.error("[Retention.Archive.LocalFS] Failed to write #{full_path}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def store(_data, _filename, settings) do
    {:error, "local_path is not configured (got: #{inspect(settings.local_path)})"}
  end
end
