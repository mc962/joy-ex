defmodule Joy.MLLP.StressTest do
  @moduledoc """
  Concurrent MLLP load runner for the test client UI.

  `run/7` streams N messages to an endpoint with a configurable concurrency
  level. Each result is sent back to the caller LiveView process as it
  completes, enabling live progress updates.

  Uses Joy.TransformSupervisor (already in the supervision tree) — no new
  supervisor needed.

  # GO-TRANSLATION: errgroup.WithContext + semaphore pattern for concurrency,
  # channel for streaming results back to the caller goroutine.
  """

  @doc """
  Send `count` copies of `hl7_string` to `host:port`, up to `concurrency` at a
  time. Sends `{:stress_result, {:ok, latency_ms} | {:error, reason}}` to
  `caller_pid` for each message, then `{:stress_complete, aggregate}` when done.

  Intended to run inside a Task.Supervisor.async_nolink task so it blocks that
  task, not the LiveView.

  Options: `:timeout_ms`, `:delay_ms` (inter-message delay within each task).
  """
  @spec run(pid(), String.t(), pos_integer(), String.t(), pos_integer(), pos_integer(), keyword()) ::
          :ok
  def run(caller_pid, host, port, hl7_string, count, concurrency, opts \\ []) do
    delay_ms = Keyword.get(opts, :delay_ms, 0)
    client_opts = Keyword.take(opts, [:timeout_ms])

    results =
      1..count
      |> Task.async_stream(
        fn _i ->
          if delay_ms > 0, do: Process.sleep(delay_ms)

          case Joy.MLLP.Client.send_message(host, port, hl7_string, client_opts) do
            {:ok, %{latency_ms: ms}} -> {:ok, ms}
            {:error, reason} -> {:error, reason}
          end
        end,
        max_concurrency: concurrency,
        timeout: :infinity,
        on_timeout: :kill_task
      )
      |> Enum.map(fn
        {:ok, result} ->
          send(caller_pid, {:stress_result, result})
          result

        {:exit, reason} ->
          r = {:error, reason}
          send(caller_pid, {:stress_result, r})
          r
      end)

    send(caller_pid, {:stress_complete, aggregate(results)})
    :ok
  end

  @doc "Compute aggregate stats from a list of per-message results."
  @spec aggregate([{:ok, non_neg_integer()} | {:error, term()}]) :: map()
  def aggregate(results) do
    latencies = for {:ok, ms} <- results, do: ms
    errors = for {:error, _} <- results, do: 1

    %{
      total: length(results),
      ok: length(latencies),
      failed: length(errors),
      min_ms: if(latencies == [], do: nil, else: Enum.min(latencies)),
      max_ms: if(latencies == [], do: nil, else: Enum.max(latencies)),
      avg_ms:
        if(latencies == [],
          do: nil,
          else: round(Enum.sum(latencies) / length(latencies))
        )
    }
  end
end
