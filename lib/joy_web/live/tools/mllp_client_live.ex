defmodule JoyWeb.Tools.MllpClientLive do
  @moduledoc "MLLP test client: one-off Send mode and concurrent Stress Test mode."
  use JoyWeb, :live_view

  @stress_message_types %{"adt_a01" => :adt_a01, "oru_r01" => :oru_r01, "orm_o01" => :orm_o01}

  defp build_sample_messages do
    now = DateTime.utc_now() |> Calendar.strftime("%Y%m%d%H%M%S")
    ctrl = fn -> :crypto.strong_rand_bytes(4) |> Base.encode16() end

    %{
      "ADT^A01" =>
        "MSH|^~\\&|SendApp|SendFac|RecvApp|RecvFac|#{now}||ADT^A01|#{ctrl.()}|P|2.5\r" <>
        "EVN|A01|#{now}\r" <>
        "PID|1||123456^^^MRN^MR||Smith^John^A||19800101|M|||123 Main St^^Springfield^IL^62701||555-555-1234|||S||123456789\r" <>
        "PV1|1|I|2-3-04^201^01||||456789^Doctor^Jane|||SUR||||1|||456789^Doctor^Jane|IP||1|A0\r",

      "ORU^R01" =>
        "MSH|^~\\&|LAB|LAB_FAC|RCV|RCV_FAC|#{now}||ORU^R01|#{ctrl.()}|P|2.5\r" <>
        "PID|1||789012^^^MRN^MR||Jones^Mary||19751215|F\r" <>
        "OBR|1|ORD001|RES001|80048^BASIC METABOLIC PANEL^CPT|||#{now}\r" <>
        "OBX|1|NM|2951-2^SODIUM^LN||140|mmol/L|136-145||||F\r" <>
        "OBX|2|NM|2823-3^POTASSIUM^LN||4.1|mmol/L|3.5-5.0||||F\r",

      "ORM^O01" =>
        "MSH|^~\\&|OE|OE_FAC|LAB|LAB_FAC|#{now}||ORM^O01|#{ctrl.()}|P|2.5\r" <>
        "PID|1||345678^^^MRN^MR||Brown^Robert||19900520|M\r" <>
        "ORC|NW|ORD002||||||#{now}|||456789^Doctor^Jane\r" <>
        "OBR|1|ORD002||85025^CBC^CPT|||#{now}\r"
    }
  end

  @impl true
  def mount(_params, _session, socket) do
    channels = Joy.Channels.list_channels()
    default_port = channels |> Enum.find(& &1.mllp_port) |> then(fn
      nil -> 4000
      ch -> ch.mllp_port
    end)
    samples = build_sample_messages()

    {:ok,
     socket
     |> assign(:page_title, "MLLP Client")
     |> assign(:channels, channels)
     |> assign(:active_tab, :send)
     |> assign(:host, "localhost")
     |> assign(:port, to_string(default_port))
     |> assign(:samples, samples)
     |> assign(:hl7_message, samples["ADT^A01"])
     # Send tab
     |> assign(:send_loading, false)
     |> assign(:send_task_ref, nil)
     |> assign(:send_result, nil)
     # Stress tab
     |> assign(:stress_count, "20")
     |> assign(:stress_concurrency, "5")
     |> assign(:stress_delay_ms, "0")
     |> assign(:stress_message_type, "adt_a01")
     |> assign(:stress_running, false)
     |> assign(:stress_task_ref, nil)
     |> assign(:stress_task_pid, nil)
     |> assign(:stress_results, [])
     |> assign(:stress_stats, nil)}
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :active_tab, String.to_existing_atom(tab))}
  end

  def handle_event("update_field", %{"field" => field, "value" => value}, socket) do
    {:noreply, assign(socket, String.to_existing_atom(field), value)}
  end

  def handle_event("load_sample", %{"type" => type}, socket) do
    samples = build_sample_messages()
    case Map.get(samples, type) do
      nil -> {:noreply, socket}
      msg -> {:noreply, assign(socket, samples: samples, hl7_message: msg)}
    end
  end

  def handle_event("select_channel", %{"port" => port}, socket) do
    {:noreply, assign(socket, :port, port)}
  end

  def handle_event("update_message", %{"value" => value}, socket) do
    {:noreply, assign(socket, :hl7_message, value)}
  end

  def handle_event("send_message", _params, socket) do
    with {:ok, _} <- validate_hl7(socket.assigns.hl7_message),
         {:ok, port} <- parse_port(socket.assigns.port) do
      host = socket.assigns.host
      hl7 = socket.assigns.hl7_message

      task =
        Task.Supervisor.async_nolink(Joy.TransformSupervisor, fn ->
          Joy.MLLP.Client.send_message(host, port, hl7)
        end)

      {:noreply,
       socket
       |> assign(:send_loading, true)
       |> assign(:send_task_ref, task.ref)
       |> assign(:send_result, nil)}
    else
      {:error, msg} ->
        {:noreply, put_flash(socket, :error, msg)}
    end
  end

  def handle_event("run_stress", _params, socket) do
    with {:ok, port} <- parse_port(socket.assigns.port),
         {:ok, count} <- parse_positive_int(socket.assigns.stress_count, "Count"),
         {:ok, concurrency} <- parse_positive_int(socket.assigns.stress_concurrency, "Concurrency"),
         {:ok, delay_ms} <- parse_non_neg_int(socket.assigns.stress_delay_ms, "Delay") do
      host = socket.assigns.host
      message_type = @stress_message_types[socket.assigns.stress_message_type] || :adt_a01
      caller = self()

      task =
        Task.Supervisor.async_nolink(Joy.TransformSupervisor, fn ->
          Joy.MLLP.StressTest.run(caller, host, port, message_type, count, concurrency,
            delay_ms: delay_ms
          )
        end)

      {:noreply,
       socket
       |> assign(:stress_running, true)
       |> assign(:stress_task_ref, task.ref)
       |> assign(:stress_task_pid, task.pid)
       |> assign(:stress_results, [])
       |> assign(:stress_stats, nil)
       |> assign(:stress_count, to_string(count))}
    else
      {:error, msg} ->
        {:noreply, put_flash(socket, :error, msg)}
    end
  end

  def handle_event("cancel_stress", _params, socket) do
    if socket.assigns.stress_task_pid do
      Process.exit(socket.assigns.stress_task_pid, :kill)
    end

    stats = Joy.MLLP.StressTest.aggregate(socket.assigns.stress_results)

    {:noreply,
     socket
     |> assign(:stress_running, false)
     |> assign(:stress_task_pid, nil)
     |> assign(:stress_task_ref, nil)
     |> assign(:stress_stats, stats)}
  end

  # Send task result (Task.Supervisor.async_nolink sends {ref, result} when the task completes)
  @impl true
  def handle_info({ref, result}, socket) when is_reference(ref) do
    if socket.assigns.send_task_ref == ref do
      Process.demonitor(ref, [:flush])
      {:noreply, assign(socket, send_loading: false, send_result: result, send_task_ref: nil)}
    else
      {:noreply, socket}
    end
  end

  # Stress test: per-message result
  def handle_info({:stress_result, result}, socket) do
    {:noreply, update(socket, :stress_results, &[result | &1])}
  end

  # Stress test: all done
  def handle_info({:stress_complete, stats}, socket) do
    {:noreply,
     socket
     |> assign(:stress_running, false)
     |> assign(:stress_task_pid, nil)
     |> assign(:stress_task_ref, nil)
     |> assign(:stress_stats, stats)}
  end

  # Task supervisor DOWN for send task (crash)
  def handle_info({:DOWN, ref, :process, _pid, reason}, socket) do
    cond do
      socket.assigns.send_task_ref == ref ->
        Process.demonitor(ref, [:flush])

        {:noreply,
         socket
         |> assign(:send_loading, false)
         |> assign(:send_task_ref, nil)
         |> assign(:send_result, {:error, "Task crashed: #{inspect(reason)}"})}

      socket.assigns.stress_task_ref == ref ->
        stats = Joy.MLLP.StressTest.aggregate(socket.assigns.stress_results)

        {:noreply,
         socket
         |> assign(:stress_running, false)
         |> assign(:stress_task_ref, nil)
         |> assign(:stress_task_pid, nil)
         |> assign(:stress_stats, stats)}

      true ->
        {:noreply, socket}
    end
  end

  def handle_info(_, socket), do: {:noreply, socket}

  # --- Helpers ---

  defp validate_hl7(msg) do
    trimmed = String.trim(msg)
    if trimmed == "", do: {:error, "HL7 message is empty"}, else: {:ok, trimmed}
  end

  defp parse_port(s) do
    case Integer.parse(String.trim(s)) do
      {n, ""} when n > 0 and n < 65536 -> {:ok, n}
      _ -> {:error, "Port must be a number between 1 and 65535"}
    end
  end

  defp parse_positive_int(s, label) do
    case Integer.parse(String.trim(s)) do
      {n, ""} when n > 0 -> {:ok, n}
      _ -> {:error, "#{label} must be a positive integer"}
    end
  end

  defp parse_non_neg_int(s, label) do
    case Integer.parse(String.trim(s)) do
      {n, ""} when n >= 0 -> {:ok, n}
      _ -> {:error, "#{label} must be 0 or greater"}
    end
  end

  # --- Render ---

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} page_title={@page_title} current_scope={@current_scope}>
    <div class="max-w-5xl mx-auto space-y-6">

      <%!-- Connection card --%>
      <div class="card bg-base-100 border border-base-300">
        <div class="card-body py-4 px-5">
          <h2 class="text-sm font-semibold text-base-content/60 uppercase tracking-wider mb-3">
            Connection
          </h2>
          <div class="flex flex-wrap gap-3 items-end">
            <div>
              <label class="label py-0 pb-1 text-xs text-base-content/60">Host</label>
              <input
                type="text"
                class="input input-bordered input-sm w-44"
                value={@host}
                phx-blur="update_field"
                phx-value-field="host"
                phx-value-value={@host}
                phx-change="update_field"
                name="host"
              />
            </div>
            <div>
              <label class="label py-0 pb-1 text-xs text-base-content/60">Port</label>
              <input
                type="text"
                class="input input-bordered input-sm w-24"
                value={@port}
                phx-blur="update_field"
                phx-value-field="port"
                phx-value-value={@port}
                phx-change="update_field"
                name="port"
              />
            </div>
            <div :if={@channels != []}>
              <label class="label py-0 pb-1 text-xs text-base-content/60">Quick-select channel</label>
              <div class="flex flex-wrap gap-1.5">
                <button
                  :for={ch <- @channels}
                  :if={ch.mllp_port}
                  phx-click="select_channel"
                  phx-value-port={ch.mllp_port}
                  class={"btn btn-xs #{if to_string(ch.mllp_port) == @port, do: "btn-primary", else: "btn-ghost border border-base-300"}"}
                >
                  {ch.name} :{ch.mllp_port}
                </button>
              </div>
            </div>
          </div>
        </div>
      </div>

      <%!-- Tabs --%>
      <div class="tabs tabs-bordered">
        <button
          class={"tab #{if @active_tab == :send, do: "tab-active"}"}
          phx-click="switch_tab"
          phx-value-tab="send"
        >
          Send
        </button>
        <button
          class={"tab #{if @active_tab == :stress, do: "tab-active"}"}
          phx-click="switch_tab"
          phx-value-tab="stress"
        >
          Stress Test
        </button>
      </div>

      <%!-- Send tab --%>
      <div :if={@active_tab == :send} class="space-y-4">
        <%!-- Sample selector + textarea --%>
        <div class="card bg-base-100 border border-base-300">
          <div class="card-body py-4 px-5 space-y-3">
            <div class="flex items-center gap-3">
              <span class="text-xs text-base-content/60 font-medium">Load sample:</span>
              <button
                :for={type <- ["ADT^A01", "ORU^R01", "ORM^O01"]}
                phx-click="load_sample"
                phx-value-type={type}
                class="btn btn-xs btn-ghost border border-base-300"
              >
                {type}
              </button>
            </div>
            <textarea
              class="textarea textarea-bordered font-mono text-xs w-full h-48 resize-y"
              phx-blur="update_message"
              phx-value-value={@hl7_message}
              name="hl7_message"
            >{@hl7_message}</textarea>
            <div class="flex justify-end">
              <button
                phx-click="send_message"
                class="btn btn-primary btn-sm"
                disabled={@send_loading}
              >
                <span :if={@send_loading} class="loading loading-spinner loading-xs"></span>
                {if @send_loading, do: "Sending…", else: "Send"}
              </button>
            </div>
          </div>
        </div>

        <%!-- Result card --%>
        <div :if={@send_result} class="card bg-base-100 border border-base-300">
          <div class="card-body py-4 px-5 space-y-3">
            <h3 class="text-sm font-semibold text-base-content/70">Result</h3>
            <div :if={match?({:ok, _}, @send_result)} class="space-y-2">
              <% {:ok, %{ack_code: code, latency_ms: ms, ack_raw: raw}} = @send_result %>
              <div class="flex items-center gap-3">
                <span class={"badge badge-sm #{ack_badge_class(code)}"}>
                  {code}
                </span>
                <span class="text-xs text-base-content/60">{ms} ms</span>
              </div>
              <pre class="text-xs bg-base-200 rounded p-3 overflow-x-auto whitespace-pre-wrap break-all">{raw}</pre>
            </div>
            <div :if={match?({:error, _}, @send_result)}>
              <% {:error, reason} = @send_result %>
              <div class="alert alert-error text-sm py-2">
                {inspect(reason)}
              </div>
            </div>
          </div>
        </div>
      </div>

      <%!-- Stress tab --%>
      <div :if={@active_tab == :stress} class="space-y-4">
        <div class="card bg-base-100 border border-base-300">
          <div class="card-body py-4 px-5 space-y-4">
            <div class="flex flex-wrap gap-4 items-end">
              <div>
                <label class="label py-0 pb-1 text-xs text-base-content/60">Messages</label>
                <input
                  type="text"
                  class="input input-bordered input-sm w-24"
                  value={@stress_count}
                  phx-blur="update_field"
                  phx-value-field="stress_count"
                  phx-value-value={@stress_count}
                  phx-change="update_field"
                  name="stress_count"
                  disabled={@stress_running}
                />
              </div>
              <div>
                <label class="label py-0 pb-1 text-xs text-base-content/60">Concurrency</label>
                <input
                  type="text"
                  class="input input-bordered input-sm w-24"
                  value={@stress_concurrency}
                  phx-blur="update_field"
                  phx-value-field="stress_concurrency"
                  phx-value-value={@stress_concurrency}
                  phx-change="update_field"
                  name="stress_concurrency"
                  disabled={@stress_running}
                />
              </div>
              <div>
                <label class="label py-0 pb-1 text-xs text-base-content/60">Delay (ms)</label>
                <input
                  type="text"
                  class="input input-bordered input-sm w-24"
                  value={@stress_delay_ms}
                  phx-blur="update_field"
                  phx-value-field="stress_delay_ms"
                  phx-value-value={@stress_delay_ms}
                  phx-change="update_field"
                  name="stress_delay_ms"
                  disabled={@stress_running}
                />
              </div>
              <div class="flex gap-2">
                <button
                  :if={!@stress_running}
                  phx-click="run_stress"
                  class="btn btn-primary btn-sm"
                >
                  Run
                </button>
                <button
                  :if={@stress_running}
                  phx-click="cancel_stress"
                  class="btn btn-error btn-sm"
                >
                  Cancel
                </button>
              </div>
            </div>

            <%!-- Progress bar (only while running or results present) --%>
            <div :if={@stress_running or @stress_results != []}>
              <div class="flex items-center justify-between text-xs text-base-content/60 mb-1">
                <span>{length(@stress_results)} / {parse_int_or(@stress_count, 0)} sent</span>
                <span :if={@stress_running} class="loading loading-dots loading-xs"></span>
              </div>
              <progress
                class="progress progress-primary w-full"
                value={length(@stress_results)}
                max={parse_int_or(@stress_count, 1)}
              >
              </progress>
            </div>
          </div>
        </div>

        <%!-- Message type selector --%>
        <div class="card bg-base-100 border border-base-300">
          <div class="card-body py-4 px-5 space-y-3">
            <div>
              <p class="text-xs font-medium text-base-content/60 mb-2">Message type</p>
              <div class="flex flex-wrap gap-2">
                <button
                  :for={{label, value} <- [{"ADT^A01 — Admission", "adt_a01"}, {"ORU^R01 — Lab Result", "oru_r01"}, {"ORM^O01 — Order", "orm_o01"}]}
                  phx-click="update_field"
                  phx-value-field="stress_message_type"
                  phx-value-value={value}
                  class={"btn btn-sm #{if @stress_message_type == value, do: "btn-primary", else: "btn-ghost border border-base-300"}"}
                  disabled={@stress_running}
                >
                  {label}
                </button>
              </div>
            </div>
            <p class="text-xs text-base-content/40">
              Each message is generated with randomized patient data (MRN, name, DOB, values).
              Messages are tagged with <code class="font-mono">MSH.3=JoyStress</code> and
              <code class="font-mono">MRN=STRESS-xxxxxx</code> for easy identification and filtering.
            </p>
          </div>
        </div>

        <%!-- Stats grid --%>
        <div :if={@stress_stats} class="card bg-base-100 border border-base-300">
          <div class="card-body py-4 px-5">
            <h3 class="text-sm font-semibold text-base-content/70 mb-3">Results</h3>
            <div class="grid grid-cols-3 md:grid-cols-6 gap-3">
              <div class="stat p-3 bg-base-200 rounded-lg">
                <div class="stat-title text-xs">Sent</div>
                <div class="stat-value text-lg">{@stress_stats.total}</div>
              </div>
              <div class="stat p-3 bg-base-200 rounded-lg">
                <div class="stat-title text-xs">OK</div>
                <div class="stat-value text-lg text-success">{@stress_stats.ok}</div>
              </div>
              <div class="stat p-3 bg-base-200 rounded-lg">
                <div class="stat-title text-xs">Failed</div>
                <div class="stat-value text-lg text-error">{@stress_stats.failed}</div>
              </div>
              <div class="stat p-3 bg-base-200 rounded-lg">
                <div class="stat-title text-xs">Min (ms)</div>
                <div class="stat-value text-lg">{@stress_stats.min_ms || "—"}</div>
              </div>
              <div class="stat p-3 bg-base-200 rounded-lg">
                <div class="stat-title text-xs">Avg (ms)</div>
                <div class="stat-value text-lg">{@stress_stats.avg_ms || "—"}</div>
              </div>
              <div class="stat p-3 bg-base-200 rounded-lg">
                <div class="stat-title text-xs">Max (ms)</div>
                <div class="stat-value text-lg">{@stress_stats.max_ms || "—"}</div>
              </div>
            </div>
          </div>
        </div>
      </div>

    </div>
    </Layouts.app>
    """
  end

  defp ack_badge_class("AA"), do: "badge-success"
  defp ack_badge_class("AE"), do: "badge-error"
  defp ack_badge_class("AR"), do: "badge-warning"
  defp ack_badge_class(_), do: "badge-ghost"

  defp parse_int_or(s, default) do
    case Integer.parse(to_string(s)) do
      {n, _} -> n
      :error -> default
    end
  end
end
