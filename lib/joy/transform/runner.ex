defmodule Joy.Transform.Runner do
  @moduledoc """
  Executes validated transform scripts in an isolated Task.

  Flow:
    1. Validate with Joy.Transform.Validator (cached, fast after first call)
    2. If valid: run in Task.Supervisor.async_nolink under Joy.TransformSupervisor
    3. Yield with timeout; shutdown task if it exceeds the limit

  Why async_nolink + yield instead of Task.await:
  async_nolink means a task crash does NOT crash the calling Pipeline GenServer.
  yield returns nil on timeout giving a clean path to handle the :timeout case.

  # GO-TRANSLATION:
  # ctx, cancel := context.WithTimeout(ctx, 5*time.Second); defer cancel()
  # result := make(chan Message, 1)
  # go func() { result <- runScript(msg) }()
  # select { case m := <-result: return m, nil; case <-ctx.Done(): return nil, err }
  """

  require Logger

  @default_timeout_ms 5_000

  @doc "Run a transform script against a message. Returns {:ok, transformed_msg} or {:error, reason}."
  @spec run(String.t(), Joy.HL7.Message.t(), pos_integer()) ::
          {:ok, Joy.HL7.Message.t()} | {:error, String.t()}
  def run(script, msg, timeout_ms \\ @default_timeout_ms) do
    with :ok <- Joy.Transform.Validator.validate(script) do
      task =
        Task.Supervisor.async_nolink(Joy.TransformSupervisor, fn ->
          wrapped = "import Joy.Transform.DSL\n" <> script

          # Code.with_diagnostics captures individual compile errors before Elixir
          # swallows them into the generic "cannot compile file (errors have been logged)"
          # CompileError. We rescue inside the callback so diagnostics are always returned.
          {outcome, diagnostics} =
            Code.with_diagnostics(fn ->
              try do
                {_val, binding} = Code.eval_string(wrapped, [msg: msg])
                {:ok, Keyword.get(binding, :msg, msg)}
              rescue
                e -> {:error, e}
              end
            end)

          case outcome do
            {:ok, _} = ok ->
              ok

            {:error, %CompileError{description: "cannot compile file" <> _}} ->
              {:error, format_diagnostics(diagnostics)}

            {:error, e} ->
              {:error, Exception.message(e)}
          end
        end)

      case Task.yield(task, timeout_ms) || Task.shutdown(task) do
        {:ok, {:ok, transformed_msg}} ->
          {:ok, transformed_msg}

        {:ok, {:error, reason}} ->
          Logger.warning("[Transform.Runner] Script error",
            script_hash: hash(script),
            reason: reason
          )
          {:error, reason}

        {:exit, reason} ->
          error = format_exit(reason)
          Logger.error("[Transform.Runner] Script crashed", script_hash: hash(script), reason: error)
          {:error, error}

        nil ->
          Logger.error("[Transform.Runner] Script timed out after #{timeout_ms}ms",
            script_hash: hash(script)
          )
          {:error, "Transform timed out after #{timeout_ms}ms"}
      end
    end
  end

  # Format diagnostics captured by Code.with_diagnostics. Each diagnostic has
  # :message, :severity, and :position ({line, col} or integer). Subtract 1 from
  # line to account for the prepended "import Joy.Transform.DSL" line.
  defp format_diagnostics(diagnostics) do
    diagnostics
    |> Enum.filter(&(&1[:severity] == :error))
    |> Enum.map(fn d ->
      line =
        case d[:position] do
          {l, _} when is_integer(l) and l > 1 -> l - 1
          l when is_integer(l) and l > 1 -> l - 1
          _ -> nil
        end

      if line, do: "Line #{line}: #{d[:message]}", else: d[:message]
    end)
    |> case do
      [] -> "Script compile error"
      msgs -> Enum.join(msgs, "\n")
    end
  end

  # Unexpected task exit (e.g. killed, non-exception crash)
  defp format_exit({%{__exception__: true} = ex, _}), do: Exception.message(ex)
  defp format_exit(reason), do: "Transform crashed: #{inspect(reason)}"

  defp hash(script) do
    :crypto.hash(:sha256, script) |> Base.encode16() |> String.slice(0, 8)
  end
end
