defmodule JoyWeb.AuditLive do
  @moduledoc "Admin-only audit log viewer with resource type and date range filtering."
  use JoyWeb, :live_view
  alias Joy.Retention

  @resource_types [
    {"All", ""},
    {"Channel", "channel"},
    {"Transform", "transform"},
    {"Destination", "destination"},
    {"Organization", "organization"},
    {"User", "user"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    entries = Joy.AuditLog.list_entries(limit: 100)
    settings = Retention.get_settings()

    {:ok,
     socket
     |> assign(:page_title, "Audit Log")
     |> assign(:entries, entries)
     |> assign(:resource_types, @resource_types)
     |> assign(:filter_resource_type, "")
     |> assign(:filter_from, "")
     |> assign(:filter_to, "")
     |> assign(:audit_settings, settings)
     |> assign(:audit_total, Joy.AuditLog.count_total())
     |> assign(:audit_purgeable, Joy.AuditLog.count_purgeable(settings.audit_retention_days))
     |> assign(:audit_oldest, Joy.AuditLog.oldest_entry_date())
     |> assign(:audit_purge_running, false)}
  end

  @impl true
  def handle_event("filter", params, socket) do
    opts = build_opts(params)
    {:noreply,
     socket
     |> assign(:entries, Joy.AuditLog.list_entries(opts))
     |> assign(:filter_resource_type, params["resource_type"] || "")
     |> assign(:filter_from, params["from"] || "")
     |> assign(:filter_to, params["to"] || "")}
  end

  def handle_event("save_audit_settings", %{"audit_retention_days" => days_str}, socket) do
    case Retention.update_settings(socket.assigns.audit_settings, %{"audit_retention_days" => days_str}) do
      {:ok, settings} ->
        {:noreply,
         socket
         |> assign(:audit_settings, settings)
         |> assign(:audit_purgeable, Joy.AuditLog.count_purgeable(settings.audit_retention_days))
         |> put_flash(:info, "Audit retention saved")}

      {:error, _cs} ->
        {:noreply, put_flash(socket, :error, "Invalid retention period — must be a positive integer")}
    end
  end

  def handle_event("purge_audit_log", _, socket) do
    days = socket.assigns.audit_settings.audit_retention_days
    pid = self()
    Task.start(fn ->
      deleted = Joy.AuditLog.purge_old(days)
      send(pid, {:audit_purge_complete, deleted})
    end)
    {:noreply, assign(socket, :audit_purge_running, true)}
  end

  @impl true
  def handle_info({:audit_purge_complete, deleted}, socket) do
    settings = Retention.get_settings()
    {:noreply,
     socket
     |> assign(:audit_purge_running, false)
     |> assign(:audit_settings, settings)
     |> assign(:audit_total, Joy.AuditLog.count_total())
     |> assign(:audit_purgeable, Joy.AuditLog.count_purgeable(settings.audit_retention_days))
     |> assign(:audit_oldest, Joy.AuditLog.oldest_entry_date())
     |> put_flash(:info, "Audit purge complete — #{deleted} entries deleted")}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  defp build_opts(params) do
    opts = [limit: 100]

    opts = case params["resource_type"] do
      nil -> opts
      ""  -> opts
      rt  -> Keyword.put(opts, :resource_type, rt)
    end

    opts = case parse_date(params["from"]) do
      nil -> opts
      dt  -> Keyword.put(opts, :from, dt)
    end

    case parse_date(params["to"]) do
      nil -> opts
      dt  -> Keyword.put(opts, :to, DateTime.add(dt, 86_399, :second))
    end
  end

  defp parse_date(""), do: nil
  defp parse_date(nil), do: nil
  defp parse_date(str) do
    case Date.from_iso8601(str) do
      {:ok, date} -> DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
      _ -> nil
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} page_title={@page_title} current_scope={@current_scope}>
    <div class="space-y-4 max-w-5xl">
      <%!-- Filter bar --%>
      <form phx-change="filter" class="flex flex-wrap gap-3 items-end">
        <div class="form-control">
          <label class="label py-1"><span class="label-text text-xs">Resource Type</span></label>
          <select name="resource_type" class="select select-bordered select-sm">
            <option :for={{label, value} <- @resource_types}
                    value={value}
                    selected={@filter_resource_type == value}>
              {label}
            </option>
          </select>
        </div>
        <div class="form-control">
          <label class="label py-1"><span class="label-text text-xs">From</span></label>
          <input type="date" name="from" value={@filter_from}
                 class="input input-bordered input-sm" />
        </div>
        <div class="form-control">
          <label class="label py-1"><span class="label-text text-xs">To</span></label>
          <input type="date" name="to" value={@filter_to}
                 class="input input-bordered input-sm" />
        </div>
      </form>

      <%!-- Results --%>
      <div class="card bg-base-100 border border-base-300 overflow-hidden">
        <div :if={@entries == []} class="flex flex-col items-center py-16 text-base-content/40">
          <.icon name="hero-clipboard-document-list" class="w-10 h-10 mb-3" />
          <p class="font-medium">No audit entries found</p>
        </div>
        <div :if={@entries != []} class="overflow-x-auto">
          <table class="table table-sm">
            <thead>
              <tr>
                <th>Time</th>
                <th>Actor</th>
                <th>Action</th>
                <th>Resource</th>
                <th>Changes</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={entry <- @entries} class="hover">
                <td class="text-xs text-base-content/60 whitespace-nowrap">
                  {format_dt(entry.inserted_at)}
                </td>
                <td class="text-xs font-mono">
                  <span :if={entry.actor_email}>{entry.actor_email}</span>
                  <span :if={!entry.actor_email} class="text-base-content/30">system</span>
                </td>
                <td>
                  <span class={"badge badge-sm #{action_badge_class(entry.action)}"}>
                    {entry.action}
                  </span>
                </td>
                <td class="text-sm">
                  <span class="text-base-content/50 text-xs">{entry.resource_type}</span>
                  <span :if={entry.resource_name} class="ml-1 font-medium">{entry.resource_name}</span>
                  <span :if={!entry.resource_name && entry.resource_id}
                        class="ml-1 font-mono text-xs text-base-content/40">#{entry.resource_id}</span>
                </td>
                <td class="text-xs font-mono text-base-content/60 max-w-xs truncate">
                  {if entry.changes && entry.changes != %{}, do: format_changes(entry.changes), else: "—"}
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
      <p class="text-xs text-base-content/40">Showing up to 100 most recent entries matching filters.</p>

      <%!-- Retention --%>
      <div class="card bg-base-100 border border-base-300">
        <div class="card-body">
          <h2 class="card-title text-base mb-1">Audit Log Retention</h2>
          <p class="text-sm text-base-content/60 mb-4">
            Permanently deletes audit entries older than the retention window. No archive — audit entries are metadata, not PHI.
          </p>

          <div class="grid grid-cols-1 sm:grid-cols-3 gap-4 mb-5">
            <div>
              <p class="text-xs text-base-content/50 uppercase tracking-wider font-medium">Total Entries</p>
              <p class="text-2xl font-bold mt-1">{@audit_total}</p>
            </div>
            <div>
              <p class="text-xs text-base-content/50 uppercase tracking-wider font-medium">Eligible for Purge</p>
              <p class="text-2xl font-bold text-warning mt-1">{@audit_purgeable}</p>
              <p class="text-xs text-base-content/40 mt-0.5">older than {@audit_settings.audit_retention_days || 365} days</p>
            </div>
            <div>
              <p class="text-xs text-base-content/50 uppercase tracking-wider font-medium">Oldest Entry</p>
              <p class="text-base font-bold mt-1">{format_dt(@audit_oldest)}</p>
            </div>
          </div>

          <form phx-submit="save_audit_settings" class="flex items-end gap-3 mb-4">
            <div class="form-control">
              <label class="label py-1"><span class="label-text text-sm">Retention window (days)</span></label>
              <input type="number" name="audit_retention_days"
                     value={@audit_settings.audit_retention_days || 365}
                     min="1" class="input input-bordered input-sm w-32" required />
            </div>
            <button type="submit" class="btn btn-primary btn-sm">Save</button>
          </form>

          <button phx-click="purge_audit_log"
                  disabled={@audit_purge_running or @audit_purgeable == 0}
                  class="btn btn-warning btn-sm">
            <span :if={@audit_purge_running} class="loading loading-spinner loading-xs"></span>
            {if @audit_purge_running, do: "Running…", else: "Purge Eligible (#{@audit_purgeable})"}
          </button>
        </div>
      </div>

    </div>
    </Layouts.app>
    """
  end

  defp format_dt(nil), do: "—"
  defp format_dt(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")

  defp format_changes(changes) do
    changes
    |> Enum.map_join(", ", fn {k, v} -> "#{k}: #{inspect(v)}" end)
  end

  defp action_badge_class(action) do
    cond do
      String.ends_with?(action, ".deleted") -> "badge-error"
      String.ends_with?(action, ".created") -> "badge-success"
      action == "user.login_failed" -> "badge-error"
      action in ["channel.started", "channel.resumed", "user.login"] -> "badge-success"
      action in ["channel.stopped", "channel.paused"] -> "badge-warning"
      true -> "badge-ghost"
    end
  end
end
