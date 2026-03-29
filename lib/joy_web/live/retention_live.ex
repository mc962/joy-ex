defmodule JoyWeb.RetentionLive do
  @moduledoc "Message log retention settings and manual purge controls."
  use JoyWeb, :live_view

  on_mount {JoyWeb.AdminAuth, :default}

  alias Joy.Retention
  alias Joy.Retention.Settings

  @impl true
  def mount(_params, _session, socket) do
    settings = Retention.get_settings()
    stats = load_stats(settings)

    {:ok,
     socket
     |> assign(:page_title, "Log Retention")
     |> assign(:settings, settings)
     |> assign(:form, to_form(Retention.change_settings(settings), as: :retention_settings))
     |> assign(:form_destination, settings.archive_destination)
     |> assign(:stats, stats)
     |> assign(:purge_running, false)
     |> assign(:show_purge_all_confirm, false)}
  end

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  # --- Settings form ---

  @impl true
  def handle_event("validate", %{"retention_settings" => params}, socket) do
    cs = Settings.changeset(socket.assigns.settings, params) |> Map.put(:action, :validate)
    {:noreply, assign(socket,
      form: to_form(cs, as: :retention_settings),
      form_destination: params["archive_destination"] || socket.assigns.form_destination)}
  end

  def handle_event("save_settings", %{"retention_settings" => params}, socket) do
    case Retention.update_settings(socket.assigns.settings, params) do
      {:ok, settings} ->
        {:noreply,
         socket
         |> assign(:settings, settings)
         |> assign(:form, to_form(Retention.change_settings(settings), as: :retention_settings))
         |> assign(:form_destination, settings.archive_destination)
         |> put_flash(:info, "Retention settings saved")}

      {:error, cs} ->
        {:noreply, assign(socket, :form, to_form(cs, as: :retention_settings))}
    end
  end

  # --- Purge actions ---

  def handle_event("purge_eligible", _, socket) do
    pid = self()
    Task.start(fn ->
      result = Retention.run_purge()
      send(pid, {:purge_complete, result})
    end)
    {:noreply, assign(socket, :purge_running, true)}
  end

  def handle_event("confirm_purge_all", _, socket) do
    {:noreply, assign(socket, :show_purge_all_confirm, true)}
  end

  def handle_event("cancel_purge_all", _, socket) do
    {:noreply, assign(socket, :show_purge_all_confirm, false)}
  end

  def handle_event("purge_all", _, socket) do
    pid = self()
    Task.start(fn ->
      result = Retention.run_purge(all: true)
      send(pid, {:purge_complete, result})
    end)
    {:noreply, assign(socket, purge_running: true, show_purge_all_confirm: false)}
  end

  @impl true
  def handle_info({:purge_complete, {:ok, result}}, socket) do
    settings = Retention.get_settings()
    stats = load_stats(settings)

    {:noreply,
     socket
     |> assign(:purge_running, false)
     |> assign(:settings, settings)
     |> assign(:stats, stats)
     |> put_flash(:info,
         "Purge complete — #{result.deleted} entries deleted" <>
         (if result.archived > 0, do: ", #{result.archived} archived", else: ""))}
  end

  def handle_info({:purge_complete, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> assign(:purge_running, false)
     |> put_flash(:error, "Purge failed: #{inspect(reason)}")}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} page_title={@page_title} current_scope={@current_scope}>
    <div class="space-y-6">

      <%!-- Stats --%>
      <div class="grid grid-cols-1 sm:grid-cols-3 gap-4">
        <div class="card bg-base-100 border border-base-300">
          <div class="card-body py-4 px-5">
            <p class="text-xs font-medium text-base-content/50 uppercase tracking-wider">Total Entries</p>
            <p class="text-3xl font-bold text-base-content mt-1">{@stats.total}</p>
          </div>
        </div>
        <div class="card bg-base-100 border border-base-300">
          <div class="card-body py-4 px-5">
            <p class="text-xs font-medium text-base-content/50 uppercase tracking-wider">Eligible for Purge</p>
            <p class="text-3xl font-bold text-warning mt-1">{@stats.purgeable}</p>
            <p class="text-xs text-base-content/40 mt-0.5">older than {@settings.retention_days} days, non-pending</p>
          </div>
        </div>
        <div class="card bg-base-100 border border-base-300">
          <div class="card-body py-4 px-5">
            <p class="text-xs font-medium text-base-content/50 uppercase tracking-wider">Oldest Entry</p>
            <p class="text-lg font-bold text-base-content mt-1">{format_dt(@stats.oldest)}</p>
          </div>
        </div>
      </div>

      <%!-- Settings --%>
      <div class="card bg-base-100 border border-base-300">
        <div class="card-body">
          <h2 class="card-title text-base mb-4">Retention Settings</h2>
          <.form for={@form} phx-change="validate" phx-submit="save_settings" class="space-y-5">

            <div class="grid grid-cols-1 md:grid-cols-3 gap-4">
              <.input field={@form[:retention_days]} type="number" label="Retention Window (days)"
                      placeholder="90" />
              <div class="flex items-end gap-4">
                <div class="flex-1">
                  <.input field={@form[:schedule_hour]} type="number" label="Run at hour (UTC 0-23)"
                          placeholder="2" />
                </div>
                <div class="form-control pb-1">
                  <label class="label cursor-pointer gap-3">
                    <span class="label-text">Schedule enabled</span>
                    <input type="hidden" name="retention_settings[schedule_enabled]" value="false" />
                    <input type="checkbox" name="retention_settings[schedule_enabled]" value="true"
                           class="checkbox checkbox-primary"
                           checked={Phoenix.HTML.Form.input_value(@form, :schedule_enabled)} />
                  </label>
                </div>
              </div>
            </div>

            <div>
              <label class="label"><span class="label-text font-medium">Archive Destination</span></label>
              <select name="retention_settings[archive_destination]" class="select select-bordered w-full max-w-xs">
                <option value="none" selected={@form_destination == "none"}>None — delete only</option>
                <option value="local_fs" selected={@form_destination == "local_fs"}>Local filesystem</option>
                <option value="s3" selected={@form_destination == "s3"}>AWS S3 (Standard)</option>
                <option value="glacier" selected={@form_destination == "glacier"}>AWS S3 Glacier</option>
              </select>
            </div>

            <%!-- Local FS config --%>
            <div :if={@form_destination == "local_fs"} class="pl-4 border-l-2 border-base-300 space-y-3">
              <.input field={@form[:local_path]} label="Archive Path"
                      placeholder="/var/joy/archive" />
            </div>

            <%!-- AWS config (shared by s3 and glacier) --%>
            <div :if={@form_destination in ["s3", "glacier"]}
                 class="pl-4 border-l-2 border-base-300 space-y-3">
              <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
                <.input field={@form[:aws_bucket]} label="S3 Bucket" placeholder="my-hl7-archive" />
                <.input field={@form[:aws_region]} label="AWS Region" placeholder="us-east-1" />
              </div>
              <.input field={@form[:aws_prefix]} label="Key Prefix"
                      placeholder="joy-archive/ (default)" />
              <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
                <.input field={@form[:aws_access_key_id]} label="Access Key ID"
                        placeholder="Leave blank to use IAM role" />
                <.input field={@form[:aws_secret_access_key]} type="password"
                        label="Secret Access Key" placeholder="Leave blank to use IAM role" />
              </div>
              <p class="text-xs text-base-content/50">
                Leave credentials blank to use an IAM instance role (recommended on EC2/ECS).
              </p>
            </div>

            <div class="card-actions justify-end">
              <button type="submit" class="btn btn-primary btn-sm">Save Settings</button>
            </div>
          </.form>
        </div>
      </div>

      <%!-- Manual Purge --%>
      <div class="card bg-base-100 border border-base-300">
        <div class="card-body">
          <h2 class="card-title text-base mb-1">Manual Purge</h2>
          <p class="text-sm text-base-content/60 mb-4">
            Purge runs archive first (if configured), then deletes. Pending entries are never deleted.
          </p>
          <div class="flex flex-wrap gap-3">
            <button phx-click="purge_eligible"
                    disabled={@purge_running or @stats.purgeable == 0}
                    class="btn btn-warning btn-sm">
              <span :if={@purge_running} class="loading loading-spinner loading-xs"></span>
              {if @purge_running, do: "Running…", else: "Archive & Purge Eligible (#{@stats.purgeable})"}
            </button>
            <button phx-click="confirm_purge_all"
                    disabled={@purge_running}
                    class="btn btn-error btn-sm btn-outline">
              Purge All Non-Pending
            </button>
          </div>
        </div>
      </div>

      <%!-- Last Run --%>
      <div :if={@settings.last_purge_at} class="card bg-base-100 border border-base-300">
        <div class="card-body py-4">
          <h2 class="text-sm font-semibold text-base-content/60 uppercase tracking-wider mb-3">Last Purge Run</h2>
          <div class="flex flex-wrap gap-6 text-sm">
            <div>
              <span class="text-base-content/50">Ran at</span>
              <span class="ml-2 font-medium">{format_dt(@settings.last_purge_at)}</span>
            </div>
            <div>
              <span class="text-base-content/50">Deleted</span>
              <span class="ml-2 font-medium text-error">{@settings.last_purge_deleted || 0}</span>
            </div>
            <div>
              <span class="text-base-content/50">Archived</span>
              <span class="ml-2 font-medium text-success">{@settings.last_purge_archived || 0}</span>
            </div>
          </div>
        </div>
      </div>

    </div>

    <%!-- Purge All confirm modal --%>
    <div :if={@show_purge_all_confirm} class="modal modal-open">
      <div class="modal-box">
        <h3 class="font-bold text-lg text-error mb-2">Purge All Non-Pending Entries?</h3>
        <p class="text-sm text-base-content/70 mb-4">
          This will permanently delete <strong>all {@stats.total} entries</strong> that are not in
          pending status, regardless of age.
          {if @settings.archive_destination != "none",
            do: "They will be archived first per your configured destination.",
            else: "No archive is configured — deletion is permanent and irreversible."}
        </p>
        <div class="modal-action">
          <button phx-click="cancel_purge_all" class="btn btn-ghost">Cancel</button>
          <button phx-click="purge_all" class="btn btn-error">Yes, Purge All</button>
        </div>
      </div>
      <div class="modal-backdrop" phx-click="cancel_purge_all"></div>
    </div>
    </Layouts.app>
    """
  end

  defp load_stats(settings) do
    %{
      total: Retention.count_total(),
      purgeable: Retention.count_purgeable(settings),
      oldest: Retention.oldest_entry_date()
    }
  end

  defp format_dt(nil), do: "—"
  defp format_dt(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")
  defp format_dt(_), do: "—"
end
