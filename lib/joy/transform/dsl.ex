defmodule Joy.Transform.DSL do
  @moduledoc """
  DSL functions available inside user-written transform scripts.

  These are injected into Code.eval_string/3 via the binding argument, forming
  the capability list for scripts. A script can ONLY call functions present in
  the binding — it cannot import or call arbitrary modules.

  Usage inside a script:
    msg = set(msg, "PID.5.1", "REDACTED")
    msg = copy(msg, "PID.3", "ZID.1")
    msg = route(msg, "audit_sns")

  # GO-TRANSLATION:
  # Go would pass a context struct and a function map or interface methods.
  # Code.eval_string/3 binding has no Go equivalent — Go would use a plugin
  # system, go-expr library, or embedded scripting language (Lua, Starlark).
  """

  require Logger

  @doc "Get a field value from the message by HL7 path."
  def get(msg, path), do: Joy.HL7.Accessor.get(msg, path)

  @doc "Set a field value in the message. Returns updated message."
  def set(msg, path, value), do: Joy.HL7.Accessor.set(msg, path, to_string(value))

  @doc "Copy a field value from one path to another. Returns updated message."
  def copy(msg, from_path, to_path) do
    value = Joy.HL7.Accessor.get(msg, from_path) || ""
    Joy.HL7.Accessor.set(msg, to_path, value)
  end

  @doc "Remove all segments with the given name from the message."
  def delete_segment(msg, seg_name), do: Joy.HL7.Accessor.delete_segment(msg, seg_name)

  @doc "Tag message for routing to a specific destination by name. Empty routes = all destinations."
  def route(msg, dest_name), do: %{msg | routes: [dest_name | msg.routes]}

  @doc "Log a message to the application logger. Returns msg unchanged."
  def log(msg, text) do
    Logger.info("[transform] #{text}")
    msg
  end

  @doc """
  Returns the keyword list binding to inject into Code.eval_string/3.
  All DSL functions plus the message itself are included.
  """
  @spec binding(Joy.HL7.Message.t()) :: keyword()
  def binding(msg) do
    [
      msg: msg,
      get: &get/2,
      set: &set/3,
      copy: &copy/3,
      delete_segment: &delete_segment/2,
      route: &route/2,
      log: &log/2
    ]
  end
end
