defmodule JoyWeb.Transforms.EditorLive do
  @moduledoc "Full-screen transform script editor with live test panel."
  use JoyWeb, :live_view

  @impl true
  def mount(%{"id" => ch_id, "transform_id" => step_id}, _session, socket) do
    channel = Joy.Channels.get_channel!(String.to_integer(ch_id))
    step = Enum.find(channel.transform_steps, &(to_string(&1.id) == step_id))

    if step == nil do
      {:ok, push_navigate(socket, to: ~p"/channels/#{ch_id}")}
    else
      {:ok,
       socket
       |> assign(:page_title, "Editor · #{step.name}")
       |> assign(:channel, channel)
       |> assign(:step, step)
       |> assign(:script, step.script)
       |> assign(:test_input, sample_hl7())
       |> assign(:test_result, nil)
       |> assign(:validation_result, validate_script(step.script))}
    end
  end

  @impl true
  def handle_event("update_script", %{"script" => script}, socket) do
    {:noreply,
     socket
     |> assign(:script, script)
     |> assign(:validation_result, validate_script(script))}
  end

  def handle_event("update_test_input", %{"input" => input}, socket) do
    {:noreply, assign(socket, :test_input, input)}
  end

  def handle_event("run_test", _, socket) do
    result =
      case Joy.HL7.parse(socket.assigns.test_input) do
        {:error, reason} ->
          {:error, "Invalid HL7 input: #{reason}"}

        {:ok, msg} ->
          case Joy.Transform.Runner.run(socket.assigns.script, msg, 5_000) do
            {:ok, transformed} -> {:ok, Joy.HL7.to_string(transformed)}
            {:error, reason} -> {:error, reason}
          end
      end

    {:noreply, assign(socket, :test_result, result)}
  end

  def handle_event("save", %{"script" => script}, socket) do
    result = Joy.Channels.upsert_transform_step(socket.assigns.channel.id, %{
      "id" => socket.assigns.step.id,
      "name" => socket.assigns.step.name,
      "script" => script,
      "position" => socket.assigns.step.position,
      "enabled" => socket.assigns.step.enabled
    })

    case result do
      {:ok, _} ->
        if Joy.ChannelManager.channel_running?(socket.assigns.channel.id) do
          Joy.Channel.Pipeline.reload_config(socket.assigns.channel.id)
        end
        {:noreply,
         socket
         |> put_flash(:info, "Transform saved")
         |> push_navigate(to: ~p"/channels/#{socket.assigns.channel.id}")}

      {:error, _cs} ->
        {:noreply, put_flash(socket, :error, "Failed to save transform")}
    end
  end

  defp validate_script(script) do
    Joy.Transform.Validator.validate(script)
  end

  defp sample_hl7 do
    "MSH|^~\\&|SENDING|FACILITY|RECEIVING|DEST|20240101120000||ADT^A01|MSG001|P|2.5\rPID|1||123456^^^HospitalA||Smith^John^A||19800101|M|||123 Main St^^Springfield^IL^62701||555-1234"
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} page_title={@page_title} current_scope={@current_scope}>
    <div class="flex flex-col h-full -m-6">
      <%!-- Toolbar --%>
      <div class="flex items-center justify-between px-6 py-3 bg-base-100 border-b border-base-300 shrink-0">
        <div class="flex items-center gap-3">
          <.link navigate={~p"/channels/#{@channel.id}"} class="btn btn-ghost btn-sm btn-square">
            <.icon name="hero-arrow-left" class="w-4 h-4" />
          </.link>
          <div>
            <p class="text-sm font-semibold">{@step.name}</p>
            <p class="text-xs text-base-content/40">{@channel.name}</p>
          </div>
          <span :if={@validation_result == :ok} class="badge badge-success badge-sm gap-1">
            <.icon name="hero-check" class="w-3 h-3" /> Valid
          </span>
          <span :if={@validation_result != :ok} class="badge badge-error badge-sm gap-1">
            <.icon name="hero-x-mark" class="w-3 h-3" /> Invalid
          </span>
        </div>
        <div class="flex gap-2">
          <.link navigate={~p"/channels/#{@channel.id}"} class="btn btn-ghost btn-sm">Cancel</.link>
          <button type="submit" form="script-form" class="btn btn-primary btn-sm" disabled={@validation_result != :ok}>
            Save Script
          </button>
        </div>
      </div>

      <%!-- Two-panel editor --%>
      <div class="flex flex-1 min-h-0">
        <%!-- Left: script editor --%>
        <form id="script-form" phx-submit="save" class="flex flex-col flex-1 min-w-0 border-r border-base-300">
          <div class="px-4 py-2 bg-base-200 border-b border-base-300 flex items-center justify-between">
            <span class="text-xs font-semibold text-base-content/60 uppercase tracking-wide">Script</span>
            <span class="text-xs text-base-content/40">Tab = 2 spaces</span>
          </div>
          <textarea
            class="flex-1 p-4 font-mono text-sm bg-base-100 resize-none focus:outline-none border-0"
            phx-hook="CodeEditor"
            id="script-editor"
            phx-change="update_script"
            name="script"
            spellcheck="false"
          >{@script}</textarea>
          <div :if={match?({:error, _}, @validation_result)} class="px-4 py-2 bg-error/10 border-t border-error/20">
            <p class="text-xs text-error font-mono">
              {elem(@validation_result, 1)}
            </p>
          </div>
        </form>

        <%!-- Right: test panel --%>
        <div class="flex flex-col w-96 shrink-0">
          <div class="flex flex-col flex-1 border-b border-base-300 min-h-0">
            <div class="px-4 py-2 bg-base-200 border-b border-base-300 flex items-center justify-between">
              <span class="text-xs font-semibold text-base-content/60 uppercase tracking-wide">Test Input</span>
              <button phx-click="run_test" class="btn btn-primary btn-xs">Run</button>
            </div>
            <textarea
              class="flex-1 p-3 font-mono text-xs bg-base-100 resize-none focus:outline-none border-0"
              phx-change="update_test_input"
              name="input"
              spellcheck="false"
              placeholder="Paste a sample HL7 message here..."
            >{@test_input}</textarea>
          </div>

          <div class="flex flex-col flex-1 min-h-0">
            <div class="px-4 py-2 bg-base-200 border-b border-base-300">
              <span class="text-xs font-semibold text-base-content/60 uppercase tracking-wide">Output</span>
            </div>
            <div class="flex-1 overflow-auto p-3">
              <div :if={@test_result == nil} class="text-xs text-base-content/30 italic">
                Run the test to see output here.
              </div>
              <pre :if={match?({:ok, _}, @test_result)}
                   class="text-xs font-mono whitespace-pre-wrap text-success-content bg-success/10 p-2 rounded"
              >{elem(@test_result, 1)}</pre>
              <pre :if={match?({:error, _}, @test_result)}
                   class="text-xs font-mono whitespace-pre-wrap text-error-content bg-error/10 p-2 rounded"
              >{elem(@test_result, 1)}</pre>
            </div>
          </div>
        </div>
      </div>
    </div>
    </Layouts.app>
    """
  end
end
