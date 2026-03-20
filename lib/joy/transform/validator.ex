defmodule Joy.Transform.Validator do
  @moduledoc """
  AST whitelist validator for user transform scripts. SECURITY CRITICAL.

  Runs BEFORE Code.eval_string — a script that fails validation never executes.

  Protection against:
  - File.rm_rf, System.cmd, Process.exit (blocked module/function calls)
  - :os.cmd, :erlang.apply (blocked erlang atom module calls)
  - spawn, send (blocked kernel-level operations)

  Threat model: semi-technical users in a healthcare environment.
  The whitelist is intentionally conservative — only HL7 DSL functions and
  safe stdlib modules are allowed.

  Results are cached by SHA-256 hash of the script in persistent_term,
  so identical scripts are only validated once per node lifetime.

  # GO-TRANSLATION:
  # go/ast + go/parser for AST walking. ast.Inspect() vs Macro.prewalk().
  # Same concept; Go requires more boilerplate. Caching via sync.Map.
  """

  @allowed_dsl ~w[get set copy delete_segment route log]a

  @allowed_kernel ~w[
    is_nil is_binary is_integer is_float is_list is_map is_atom is_boolean
    length hd tl elem to_string inspect trunc round div rem abs max min not
    put_in get_in update_in
  ]a

  @allowed_modules [String, Integer, Float, List, Map, Enum, Regex, DateTime, Date, NaiveDateTime]

  @blocked_functions ~w[apply spawn spawn_link spawn_monitor send import require use
                        quote unquote eval Code System File Process Node Port IO]a

  @doc "Validate a transform script. Returns :ok or {:error, human-readable message}."
  @spec validate(String.t()) :: :ok | {:error, String.t()}
  def validate(script) when is_binary(script) do
    hash = :crypto.hash(:sha256, script) |> Base.encode16()
    cache_key = {__MODULE__, 2, hash}

    case :persistent_term.get(cache_key, nil) do
      nil ->
        result = do_validate(script)
        :persistent_term.put(cache_key, result)
        result

      cached ->
        cached
    end
  end

  defp do_validate(script) do
    case Code.string_to_quoted(script, warn_on_unnecessary_quotes: false) do
      {:ok, ast} ->
        case Macro.prewalk(ast, :ok, &check_node/2) do
          {_, :ok} -> :ok
          {_, {:error, msg}} -> {:error, msg}
        end

      {:error, {meta, msg, token}} ->
        line = Keyword.get(meta, :line, "?")
        {:error, "Syntax error on line #{line}: #{msg}#{token}"}
    end
  end

  # Block explicitly forbidden function names
  defp check_node({func, _meta, _args} = node, :ok) when func in @blocked_functions do
    {node, {:error, "`#{func}` is not allowed in transform scripts"}}
  end

  # Allow DSL functions
  defp check_node({func, _meta, _args} = node, :ok) when func in @allowed_dsl do
    {node, :ok}
  end

  # Allow safe kernel functions
  defp check_node({func, _meta, _args} = node, :ok) when func in @allowed_kernel do
    {node, :ok}
  end

  # Allow module calls ONLY for whitelisted modules
  defp check_node({{:., _, [{:__aliases__, _, parts}, _func]}, _, _} = node, :ok) do
    mod = Module.concat(parts)
    if mod in @allowed_modules do
      {node, :ok}
    else
      {node, {:error, "Module `#{inspect(mod)}` is not allowed in transform scripts"}}
    end
  end

  # Elixir may emit Kernel functions as :"Elixir.Kernel".func in certain AST positions
  # (e.g. string interpolation #{} compiles to Kernel.to_string in some versions).
  # Allow them if the function is already in the safe kernel list.
  defp check_node({{:., _, [:"Elixir.Kernel", func]}, _, _} = node, :ok)
       when func in @allowed_kernel do
    {node, :ok}
  end

  # Block all other erlang atom module calls: :erlang.apply, :os.cmd, etc.
  defp check_node({{:., _, [mod_atom, func]}, _, _} = node, :ok)
       when is_atom(mod_atom) and mod_atom not in [nil] do
    {node, {:error, "Erlang module call `:#{mod_atom}.#{func}` is not allowed in transform scripts"}}
  end

  # Allow everything else: literals, variables, operators, if/case/cond
  defp check_node(node, acc), do: {node, acc}
end
