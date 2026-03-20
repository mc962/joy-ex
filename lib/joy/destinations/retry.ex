defmodule Joy.Destinations.Retry do
  @moduledoc """
  Exponential backoff with jitter for destination delivery retries.

  Jitter (random component) prevents thundering herd: if many channels
  retry simultaneously after a shared backend recovers, without jitter they
  all retry at the exact same time and overwhelm it again.

  Formula: base_ms * 2^attempt_number + rand(0..base_ms), capped at 30s.

  # GO-TRANSLATION:
  # Manual loop with time.Sleep or a retry library. The recursive Elixir approach
  # is functionally identical but uses tail recursion instead of a for loop.
  # Go: for i := 0; i < maxAttempts; i++ { err = fn(); if err == nil { return }; time.Sleep(backoff) }
  """

  @max_sleep_ms 30_000

  @doc "Call fun/0 up to `attempts` times with exponential backoff between tries."
  @spec with_retry((-> :ok | {:error, any()}), pos_integer(), pos_integer()) ::
          :ok | {:error, any()}
  def with_retry(fun, attempts, base_ms \\ 1_000)

  def with_retry(fun, 1, _base_ms) do
    fun.()
  end

  def with_retry(fun, attempts, base_ms) when attempts > 1 do
    case fun.() do
      :ok ->
        :ok

      {:error, _reason} ->
        attempt_num = 0  # First failure — sleep before retry
        sleep_ms = backoff_ms(base_ms, attempt_num)
        Process.sleep(sleep_ms)
        with_retry(fun, attempts - 1, base_ms)

      _ ->
        {:error, "unexpected return from destination adapter"}
    end
  end

  @doc "Exponential backoff + jitter, capped at 30 seconds."
  def backoff_ms(base_ms, attempt) do
    exp = trunc(base_ms * :math.pow(2, attempt))
    jitter = :rand.uniform(base_ms)
    min(exp + jitter, @max_sleep_ms)
  end
end
