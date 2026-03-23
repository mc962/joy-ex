defmodule JoyWeb.Channels.ShowLive do
  @moduledoc "Channel detail page: config, transforms, destinations, TLS, IP allowlist, alerting."
  use JoyWeb, :live_view
  require Logger
  alias Joy.Channels
  alias Joy.Channels.{TransformStep, DestinationConfig}

  @adapter_labels %{
    "aws_sns" => "AWS SNS", "aws_sqs" => "AWS SQS", "http_webhook" => "HTTP Webhook",
    "mllp_forward" => "MLLP Forward", "redis_queue" => "Redis Queue", "file" => "File",
    "sink" => "Message Sink"
  }

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    channel = Channels.get_channel!(String.to_integer(id))
    running? = Joy.ChannelManager.channel_running?(channel.id)

    stats =
      if running?, do: Joy.Channel.Pipeline.get_stats(channel.id),
      else: default_stats(channel)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Joy.PubSub, "channels")
      Phoenix.PubSub.subscribe(Joy.PubSub, "channel:#{channel.id}:stats")
    end

    {:ok,
     socket
     |> assign(:page_title, channel.name)
     |> assign(:channel, channel)
     |> assign(:running?, running?)
     |> assign(:stats, stats)
     |> assign(:show_transform_modal, false)
     |> assign(:show_dest_modal, false)
     |> assign(:transform_form, nil)
     |> assign(:dest_form, nil)
     |> assign(:editing_transform, nil)
     |> assign(:editing_dest, nil)
     |> assign(:selected_adapter, "http_webhook")
     |> assign(:ip_error, nil)
     |> assign(:tls_form, nil)
     |> assign(:alert_form, nil)
     |> assign(:dispatch_form, nil)
     |> assign(:tls_key_editing, false)
     |> assign(:pin_form, nil)
     |> assign(:available_nodes, [])}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    channel = socket.assigns.channel
    socket = case socket.assigns.live_action do
      :new_transform ->
        cs = TransformStep.changeset(%TransformStep{}, %{channel_id: channel.id, position: length(channel.transform_steps)})
        assign(socket, show_transform_modal: true, transform_form: to_form(cs), editing_transform: nil)

      :edit_transform ->
        step = Enum.find(channel.transform_steps, &(to_string(&1.id) == params["transform_id"]))
        if step do
          cs = TransformStep.changeset(step, %{})
          assign(socket, show_transform_modal: true, transform_form: to_form(cs), editing_transform: step)
        else
          socket
        end

      :new_destination ->
        cs = DestinationConfig.changeset(%DestinationConfig{}, %{channel_id: channel.id, config: %{}})
        assign(socket, show_dest_modal: true, dest_form: to_form(cs), editing_dest: nil, selected_adapter: "http_webhook")

      :edit_destination ->
        dest = Enum.find(channel.destination_configs, &(to_string(&1.id) == params["dest_id"]))
        if dest do
          cs = DestinationConfig.changeset(dest, %{})
          assign(socket, show_dest_modal: true, dest_form: to_form(cs), editing_dest: dest, selected_adapter: dest.adapter)
        else
          socket
        end

      _ ->
        assign(socket,
          show_transform_modal: false, show_dest_modal: false,
          tls_form: to_form(Channels.Channel.changeset(channel, %{})),
          alert_form: to_form(Channels.Channel.changeset(channel, %{})),
          dispatch_form: to_form(Channels.Channel.changeset(channel, %{})),
          pin_form: to_form(Channels.Channel.changeset(channel, %{})),
          available_nodes: live_nodes()
        )
    end
    {:noreply, socket}
  end

  @impl true
  def handle_info({:stats_updated, stats}, socket) do
    {:noreply, assign(socket, :stats, stats)}
  end

  def handle_info({:channel_updated, channel}, socket) when channel.id == socket.assigns.channel.id do
    {:noreply, assign(socket, :channel, channel)}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  @impl true
  def handle_event("start_channel", _, socket) do
    channel = socket.assigns.channel
    Joy.ChannelManager.start_channel(channel)
    Channels.set_started(channel, true)
    {:noreply, assign(socket, :running?, true)}
  end

  def handle_event("stop_channel", _, socket) do
    channel = socket.assigns.channel
    Joy.ChannelManager.stop_channel(channel.id)
    Channels.set_started(channel, false)
    {:noreply, assign(socket, :running?, false)}
  end

  def handle_event("pause_channel", _, socket) do
    Joy.ChannelManager.pause_channel(socket.assigns.channel.id)
    channel = Channels.get_channel!(socket.assigns.channel.id)
    {:noreply, socket |> assign(:channel, channel) |> assign(:stats, Map.put(socket.assigns.stats, :paused, true))}
  end

  def handle_event("resume_channel", _, socket) do
    Joy.ChannelManager.resume_channel(socket.assigns.channel.id)
    channel = Channels.get_channel!(socket.assigns.channel.id)
    {:noreply, socket |> assign(:channel, channel) |> assign(:stats, Map.put(socket.assigns.stats, :paused, false))}
  end

  def handle_event("close_transform_modal", _, socket) do
    {:noreply, push_patch(socket, to: ~p"/channels/#{socket.assigns.channel.id}")}
  end

  def handle_event("close_dest_modal", _, socket) do
    {:noreply, push_patch(socket, to: ~p"/channels/#{socket.assigns.channel.id}")}
  end

  def handle_event("adapter_changed", %{"destination_config" => %{"adapter" => adapter}}, socket) do
    {:noreply, assign(socket, :selected_adapter, adapter)}
  end

  def handle_event("save_transform", %{"transform_step" => params}, socket) do
    result = Channels.upsert_transform_step(socket.assigns.channel.id, params)
    case result do
      {:ok, _} ->
        Joy.Channel.Pipeline.reload_config(socket.assigns.channel.id)
        channel = Channels.get_channel!(socket.assigns.channel.id)
        {:noreply,
         socket
         |> assign(:channel, channel)
         |> push_patch(to: ~p"/channels/#{channel.id}")}

      {:error, cs} ->
        {:noreply, assign(socket, :transform_form, to_form(cs))}
    end
  end

  def handle_event("delete_transform", %{"id" => id}, socket) do
    step = Enum.find(socket.assigns.channel.transform_steps, &(to_string(&1.id) == id))
    if step, do: Channels.delete_transform_step(step)
    channel = Channels.get_channel!(socket.assigns.channel.id)
    remaining_ids = Enum.map(channel.transform_steps, & &1.id)
    if remaining_ids != [], do: Channels.reorder_transform_steps(socket.assigns.channel.id, remaining_ids)
    Joy.Channel.Pipeline.reload_config(socket.assigns.channel.id)
    channel = Channels.get_channel!(socket.assigns.channel.id)
    {:noreply, assign(socket, :channel, channel)}
  end

  def handle_event("toggle_transform", %{"id" => id}, socket) do
    step = Enum.find(socket.assigns.channel.transform_steps, &(to_string(&1.id) == id))
    if step do
      Channels.upsert_transform_step(socket.assigns.channel.id, %{"id" => step.id, "enabled" => !step.enabled})
    end
    Joy.Channel.Pipeline.reload_config(socket.assigns.channel.id)
    channel = Channels.get_channel!(socket.assigns.channel.id)
    {:noreply, assign(socket, :channel, channel)}
  end

  def handle_event("move_transform", %{"id" => id, "value" => pos_str}, socket) do
    steps = socket.assigns.channel.transform_steps
    step = Enum.find(steps, &(to_string(&1.id) == id))

    if step do
      target =
        pos_str
        |> Integer.parse()
        |> case do
          {n, _} -> n - 1
          :error -> step.position
        end
        |> max(0)
        |> min(length(steps) - 1)

      ordered_ids =
        steps
        |> Enum.reject(&(&1.id == step.id))
        |> List.insert_at(target, step)
        |> Enum.map(& &1.id)

      Channels.reorder_transform_steps(socket.assigns.channel.id, ordered_ids)
      Joy.Channel.Pipeline.reload_config(socket.assigns.channel.id)
      channel = Channels.get_channel!(socket.assigns.channel.id)
      {:noreply, assign(socket, :channel, channel)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("save_destination", %{"destination_config" => params}, socket) do
    result = Channels.upsert_destination_config(socket.assigns.channel.id, params)
    case result do
      {:ok, _} ->
        Joy.Channel.Pipeline.reload_config(socket.assigns.channel.id)
        channel = Channels.get_channel!(socket.assigns.channel.id)
        {:noreply,
         socket
         |> assign(:channel, channel)
         |> push_patch(to: ~p"/channels/#{channel.id}")}

      {:error, cs} ->
        {:noreply, assign(socket, :dest_form, to_form(cs))}
    end
  end

  def handle_event("delete_destination", %{"id" => id}, socket) do
    dest = Enum.find(socket.assigns.channel.destination_configs, &(to_string(&1.id) == id))
    if dest, do: Channels.delete_destination_config(dest)
    Joy.Channel.Pipeline.reload_config(socket.assigns.channel.id)
    channel = Channels.get_channel!(socket.assigns.channel.id)
    {:noreply, assign(socket, :channel, channel)}
  end

  def handle_event("add_allowed_ip", %{"ip" => raw_ip}, socket) do
    if admin?(socket) do
      ip = String.trim(raw_ip)
      channel = socket.assigns.channel

      case Channels.update_channel(channel, %{allowed_ips: channel.allowed_ips ++ [ip]}) do
        {:ok, updated} ->
          {:noreply, socket |> assign(:channel, updated) |> assign(:ip_error, nil)}

        {:error, changeset} ->
          {msg, _} = changeset.errors[:allowed_ips]
          {:noreply, assign(socket, :ip_error, msg)}
      end
    else
      {:noreply, put_flash(socket, :error, "Admin access required.")}
    end
  end

  def handle_event("remove_allowed_ip", %{"ip" => ip}, socket) do
    if admin?(socket) do
      channel = socket.assigns.channel
      {:ok, updated} = Channels.update_channel(channel, %{allowed_ips: List.delete(channel.allowed_ips, ip)})
      {:noreply, assign(socket, :channel, updated)}
    else
      {:noreply, put_flash(socket, :error, "Admin access required.")}
    end
  end

  def handle_event("toggle_destination", %{"id" => id}, socket) do
    dest = Enum.find(socket.assigns.channel.destination_configs, &(to_string(&1.id) == id))
    if dest do
      Channels.upsert_destination_config(socket.assigns.channel.id,
        %{"id" => dest.id, "enabled" => !dest.enabled})
    end
    Joy.Channel.Pipeline.reload_config(socket.assigns.channel.id)
    channel = Channels.get_channel!(socket.assigns.channel.id)
    {:noreply, assign(socket, :channel, channel)}
  end

  def handle_event("save_tls", %{"channel" => params}, socket) do
    if admin?(socket) do
      # Don't overwrite existing key with empty string (key field hidden when not editing)
      params = if params["tls_key_pem"] == "" or params["tls_key_pem"] == nil,
        do: Map.delete(params, "tls_key_pem"),
        else: params

      # Parse cert to populate tls_cert_expires_at so CertMonitor can check expiry
      params = case params["tls_cert_pem"] do
        pem when is_binary(pem) and pem != "" ->
          case Joy.CertParser.parse(pem) do
            {:ok, %{expires_at: dt}} -> Map.put(params, "tls_cert_expires_at", dt)
            _ -> params
          end
        _ -> params
      end

      case Channels.update_channel(socket.assigns.channel, params) do
        {:ok, updated} ->
          # Restart server to pick up new TLS config (stop + start pipeline tree)
          if Joy.ChannelManager.channel_running?(updated.id) do
            Joy.ChannelManager.stop_channel(updated.id)
            with {:error, reason} <- Joy.ChannelManager.start_channel(updated) do
              Logger.error("[ShowLive] Failed to restart channel #{updated.id} after TLS save: #{inspect(reason)}")
            end
          end
          {:noreply,
           socket
           |> assign(:channel, updated)
           |> assign(:tls_key_editing, false)
           |> assign(:tls_form, to_form(Channels.Channel.changeset(updated, %{})))
           |> put_flash(:info, "TLS configuration saved.")}

        {:error, cs} ->
          Logger.error("[ShowLive] TLS save failed: #{inspect(cs.errors)}")
          {:noreply, assign(socket, :tls_form, to_form(cs))}
      end
    else
      {:noreply, put_flash(socket, :error, "Admin access required.")}
    end
  end

  def handle_event("save_alert", %{"channel" => params}, socket) do
    case Channels.update_channel(socket.assigns.channel, params) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign(:channel, updated)
         |> assign(:alert_form, to_form(Channels.Channel.changeset(updated, %{})))
         |> put_flash(:info, "Alert configuration saved.")}

      {:error, cs} ->
        {:noreply, assign(socket, :alert_form, to_form(cs))}
    end
  end

  def handle_event("save_dispatch", %{"channel" => params}, socket) do
    case Channels.update_channel(socket.assigns.channel, params) do
      {:ok, updated} ->
        Joy.Channel.Pipeline.reload_config(updated.id)
        {:noreply,
         socket
         |> assign(:channel, updated)
         |> assign(:dispatch_form, to_form(Channels.Channel.changeset(updated, %{})))
         |> put_flash(:info, "Dispatch configuration saved.")}

      {:error, cs} ->
        {:noreply, assign(socket, :dispatch_form, to_form(cs))}
    end
  end

  def handle_event("edit_tls_key", _, socket) do
    {:noreply, assign(socket, :tls_key_editing, true)}
  end

  def handle_event("save_pin", %{"channel" => params}, socket) do
    if admin?(socket) do
      channel = socket.assigns.channel
      # Clear pin when empty string submitted (the "— No pin —" option)
      params = if params["pinned_node"] == "", do: Map.put(params, "pinned_node", nil), else: params

      case Channels.update_channel(channel, params) do
        {:ok, updated} ->
          # Restart the channel so Horde re-places it on the new pinned node
          if socket.assigns.running? do
            Joy.ChannelManager.stop_channel(updated.id)
            with {:error, reason} <- Joy.ChannelManager.start_channel(updated) do
              Logger.error("[ShowLive] Failed to restart channel #{updated.id} after pin change: #{inspect(reason)}")
            end
          end
          {:noreply,
           socket
           |> assign(:channel, updated)
           |> assign(:pin_form, to_form(Channels.Channel.changeset(updated, %{})))
           |> put_flash(:info, "Node pinning saved.")}

        {:error, cs} ->
          {:noreply, assign(socket, :pin_form, to_form(cs))}
      end
    else
      {:noreply, put_flash(socket, :error, "Admin access required.")}
    end
  end

  defp admin?(socket), do: socket.assigns.current_scope.user.is_admin

  defp live_nodes do
    [node() | Node.list()]
    |> Enum.sort()
    |> Enum.map(&Atom.to_string/1)
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :adapter_labels, @adapter_labels)
    ~H"""
    <Layouts.app flash={@flash} page_title={@page_title} current_scope={@current_scope}>
    <div class="space-y-6 max-w-4xl">
      <%!-- Channel header --%>
      <div class="card bg-base-100 border border-base-300">
        <div class="card-body p-5">
          <div class="flex items-center justify-between flex-wrap gap-3">
            <div>
              <div class="flex items-center gap-2">
                <h2 class="text-xl font-bold">{@channel.name}</h2>
                <span :if={@running? and not @channel.paused} class="badge badge-success">Running</span>
                <span :if={@running? and @channel.paused} class="badge badge-warning">Paused</span>
                <span :if={not @running?} class="badge badge-ghost">Stopped</span>
                <span :if={@channel.tls_enabled} class="badge badge-info badge-sm">TLS</span>
              </div>
              <p class="text-sm text-base-content/60 mt-0.5">
                MLLP port {@channel.mllp_port}
                <span :if={@channel.description}> · {@channel.description}</span>
              </p>
            </div>
            <div class="flex items-center gap-2">
              <.link navigate={~p"/channels/#{@channel.id}/messages"} class="btn btn-ghost btn-sm">
                <.icon name="hero-queue-list" class="w-4 h-4" /> Messages
              </.link>
              <button :if={not @running?} phx-click="start_channel" class="btn btn-success btn-sm">Start</button>
              <button :if={@running? and not @channel.paused} phx-click="pause_channel"
                      class="btn btn-warning btn-sm">Pause</button>
              <button :if={@running? and @channel.paused} phx-click="resume_channel"
                      class="btn btn-success btn-sm">Resume</button>
              <button :if={@running?} phx-click="stop_channel" class="btn btn-ghost btn-sm">Stop</button>
            </div>
          </div>

          <%!-- Today's stats + session stats --%>
          <div :if={@running?} class="flex gap-6 mt-4 pt-4 border-t border-base-300 text-sm flex-wrap">
            <div>
              <span class="text-base-content/50 text-xs uppercase tracking-wide">Today Recv</span>
              <span class="ml-2 font-semibold">{@stats[:today_received] || 0}</span>
            </div>
            <div>
              <span class="text-base-content/50 text-xs uppercase tracking-wide">Today Proc</span>
              <span class="ml-2 font-semibold text-success">{@stats[:today_processed] || 0}</span>
            </div>
            <div>
              <span class="text-base-content/50 text-xs uppercase tracking-wide">Today Fail</span>
              <span class="ml-2 font-semibold text-error">{@stats[:today_failed] || 0}</span>
            </div>
            <div>
              <span class="text-base-content/50 text-xs uppercase tracking-wide">Queue Depth</span>
              <span class="ml-2 font-semibold">{@stats[:retry_queue_depth] || 0}</span>
            </div>
            <div>
              <span class="text-base-content/50 text-xs uppercase tracking-wide">Session Fail</span>
              <span class="ml-2 font-semibold text-error">{@stats.failed_count}</span>
            </div>
          </div>
        </div>
      </div>

      <%!-- Transform Steps --%>
      <div class="card bg-base-100 border border-base-300">
        <div class="card-body p-5">
          <div class="flex items-center justify-between mb-4">
            <h3 class="font-semibold">Transform Steps</h3>
            <.link patch={~p"/channels/#{@channel.id}/transforms/new"} class="btn btn-ghost btn-sm">
              <.icon name="hero-plus" class="w-4 h-4" /> Add
            </.link>
          </div>

          <div :if={@channel.transform_steps == []} class="text-sm text-base-content/40 py-4 text-center">
            No transforms configured — messages pass through unchanged.
          </div>

          <div class="space-y-2">
            <div :for={step <- @channel.transform_steps}
                 class="flex items-center gap-3 p-3 rounded-lg border border-base-300 bg-base-200/50">
              <input type="number" min="1" max={length(@channel.transform_steps)} value={step.position + 1}
                     phx-keyup="move_transform" phx-key="Enter"
                     phx-value-id={step.id}
                     class="w-9 text-center text-xs font-mono text-base-content/40 bg-transparent border border-transparent rounded hover:border-base-300 focus:border-primary focus:outline-none focus:text-base-content px-0.5 [appearance:textfield] [&::-webkit-inner-spin-button]:appearance-none [&::-webkit-outer-spin-button]:appearance-none" />
              <div class="flex-1 min-w-0">
                <p class="font-medium text-sm">{step.name}</p>
                <p class="text-xs text-base-content/40 font-mono truncate">{String.slice(step.script, 0, 60)}...</p>
              </div>
              <div class="flex items-center gap-1 shrink-0">
                <button phx-click="toggle_transform" phx-value-id={step.id}
                        class={"btn btn-xs #{if step.enabled, do: "btn-ghost", else: "btn-warning"}"}>
                  {if step.enabled, do: "Disable", else: "Enable"}
                </button>
                <.link navigate={~p"/channels/#{@channel.id}/transforms/#{step.id}/editor"}
                       class="btn btn-ghost btn-xs">Edit</.link>
                <button phx-click="delete_transform" phx-value-id={step.id}
                        data-confirm={"Delete transform '#{step.name}'?"}
                        class="btn btn-ghost btn-xs text-error">
                  <.icon name="hero-trash" class="w-3.5 h-3.5" />
                </button>
              </div>
            </div>
          </div>
        </div>
      </div>

      <%!-- Destinations --%>
      <div class="card bg-base-100 border border-base-300">
        <div class="card-body p-5">
          <div class="flex items-center justify-between mb-4">
            <h3 class="font-semibold">Destinations</h3>
            <.link patch={~p"/channels/#{@channel.id}/destinations/new"} class="btn btn-ghost btn-sm">
              <.icon name="hero-plus" class="w-4 h-4" /> Add
            </.link>
          </div>

          <div :if={@channel.destination_configs == []} class="text-sm text-base-content/40 py-4 text-center">
            No destinations configured — processed messages will not be forwarded.
          </div>

          <div class="space-y-2">
            <div :for={dest <- @channel.destination_configs}
                 class="flex items-center gap-3 p-3 rounded-lg border border-base-300 bg-base-200/50">
              <div class="flex-1 min-w-0">
                <p class="font-medium text-sm">{dest.name}</p>
                <p class="text-xs text-base-content/40 mt-0.5">
                  Retry {dest.retry_attempts}× at {dest.retry_base_ms}ms base
                </p>
              </div>
              <div class="flex items-center gap-1 shrink-0">
                <span class="badge badge-outline badge-xs mr-1">{@adapter_labels[dest.adapter] || dest.adapter}</span>
                <button phx-click="toggle_destination" phx-value-id={dest.id}
                        class={"btn btn-xs #{if dest.enabled, do: "btn-ghost", else: "btn-warning"}"}>
                  {if dest.enabled, do: "Disable", else: "Enable"}
                </button>
                <.link patch={~p"/channels/#{@channel.id}/destinations/#{dest.id}/edit"}
                       class="btn btn-ghost btn-xs">Edit</.link>
                <button phx-click="delete_destination" phx-value-id={dest.id}
                        data-confirm={"Delete destination '#{dest.name}'?"}
                        class="btn btn-ghost btn-xs text-error">
                  <.icon name="hero-trash" class="w-3.5 h-3.5" />
                </button>
              </div>
            </div>
          </div>
        </div>
      </div>

      <%!-- IP Allowlist (admin only) --%>
      <%= if @current_scope.user.is_admin do %>
      <div class="card bg-base-100 border border-base-300">
        <div class="card-body p-5">
          <h3 class="font-semibold mb-1">IP Allowlist</h3>
          <p class="text-sm text-base-content/50 mb-4">
            Restrict inbound MLLP connections to specific addresses. Accepts plain IPs
            (<code class="font-mono">10.0.0.5</code>) or CIDR ranges
            (<code class="font-mono">10.0.0.0/24</code>). Empty = accept from any IP.
            Changes apply to new connections immediately; existing connections are unaffected.
          </p>

          <div :if={@channel.allowed_ips == []} class="text-sm text-base-content/40 py-1 mb-3">
            No restrictions — accepting connections from any IP.
          </div>

          <div :if={@channel.allowed_ips != []} class="space-y-1 mb-4">
            <div :for={ip <- @channel.allowed_ips} class="flex items-center gap-2">
              <span class="font-mono text-sm flex-1">{ip}</span>
              <button phx-click="remove_allowed_ip" phx-value-ip={ip}
                      class="btn btn-ghost btn-xs text-error">
                <.icon name="hero-x-mark" class="w-3.5 h-3.5" />
              </button>
            </div>
          </div>

          <form phx-submit="add_allowed_ip" class="flex gap-2">
            <input type="text" name="ip" class="input input-bordered input-sm flex-1"
                   placeholder="192.168.1.0/24 or 10.0.0.5" />
            <button type="submit" class="btn btn-sm btn-ghost">
              <.icon name="hero-plus" class="w-4 h-4" /> Add
            </button>
          </form>
          <p :if={@ip_error} class="text-error text-xs mt-1">{@ip_error}</p>
        </div>
      </div>
      <% end %>

      <%!-- TLS Configuration (admin only) --%>
      <%= if @current_scope.user.is_admin do %>
      <div class="card bg-base-100 border border-base-300">
        <div class="card-body p-5">
          <h3 class="font-semibold mb-1">TLS Configuration</h3>
          <p class="text-sm text-base-content/50 mb-4">
            Enable TLS to encrypt MLLP traffic in transit. Paste PEM-encoded certificate
            material below — cert material is stored encrypted in the database (no file paths needed).
            Saving restarts the channel to apply the new config.
          </p>

          <%!-- Cert expiry warning --%>
          <% cert_info = Joy.CertParser.parse(@channel.tls_cert_pem) %>
          <div :if={match?({:ok, %{expires_at: _}}, cert_info)} class="mb-4">
            <% {:ok, %{expires_at: exp_dt, cn: cn, issuer: issuer, sans: sans}} = cert_info %>
            <% days_left = DateTime.diff(exp_dt, DateTime.utc_now(), :day) %>
            <div class={"alert text-sm py-2 #{if days_left <= 30, do: "alert-warning", else: "alert-info"}"}>
              <div>
                <p class="font-medium">
                  {if cn, do: cn, else: "(no CN)"}
                  <span class="font-normal opacity-70 ml-2">issued by {issuer || "unknown"}</span>
                </p>
                <p class="text-xs mt-0.5">
                  SANs: {if sans == [], do: "none", else: Enum.join(sans, ", ")}
                </p>
                <p class="text-xs mt-0.5">
                  Expires: {Calendar.strftime(exp_dt, "%Y-%m-%d")}
                  ({days_left} day{if days_left == 1, do: "", else: "s"} remaining)
                  ({if days_left <= 0, do: "⚠ EXPIRED", else: if(days_left <= 30, do: "— renew soon", else: "")})
                </p>
              </div>
            </div>
          </div>

          <.form :if={@tls_form} for={@tls_form} phx-submit="save_tls" class="space-y-4">
            <div class="form-control">
              <label class="label cursor-pointer justify-start gap-3">
                <input type="checkbox" class="toggle toggle-sm toggle-info"
                       name="channel[tls_enabled]" value="true"
                       checked={@channel.tls_enabled} />
                <span class="label-text">Enable TLS</span>
              </label>
            </div>

            <div class="grid grid-cols-1 gap-3">
              <%!-- Server Certificate (public — shown freely) --%>
              <div class="form-control">
                <div class="label">
                  <span class="label-text">Server Certificate (PEM)</span>
                  <button :if={@channel.tls_cert_pem && @channel.tls_cert_pem != ""}
                          type="button"
                          onclick={"navigator.clipboard.writeText(document.getElementById('tls-cert-display').value)
                                   .then(() => { this.textContent = 'Copied!'; setTimeout(() => this.textContent = 'Copy cert', 2000); })"}
                          class="btn btn-xs btn-ghost">
                    Copy cert
                  </button>
                </div>
                <textarea
                  id="tls-cert-display"
                  class="textarea textarea-bordered font-mono text-xs h-32 resize-y"
                  name="channel[tls_cert_pem]"
                  placeholder={"-----BEGIN CERTIFICATE-----\n...\n-----END CERTIFICATE-----"}
                >{@channel.tls_cert_pem}</textarea>
                <p :for={msg <- Enum.map(@tls_form[:tls_cert_pem].errors, &translate_error/1)}
                   class="mt-1 text-sm text-error flex gap-1 items-center">
                  <.icon name="hero-exclamation-circle" class="size-4 shrink-0" />{msg}
                </p>
                <p class="text-xs text-base-content/50 mt-1">
                  Share this certificate with connecting systems that need to verify Joy's identity.
                </p>
              </div>

              <%!-- Private Key (write-only after initial save) --%>
              <div class="form-control">
                <label class="label"><span class="label-text">Private Key (PEM)</span></label>
                <div :if={@channel.tls_key_pem && not @tls_key_editing} class="flex items-center gap-3 p-3 bg-base-200 rounded-lg">
                  <.icon name="hero-lock-closed" class="w-4 h-4 text-success shrink-0" />
                  <span class="text-sm flex-1">Private key is configured</span>
                  <button type="button" phx-click="edit_tls_key" class="btn btn-xs btn-ghost">Replace</button>
                </div>
                <textarea
                  :if={is_nil(@channel.tls_key_pem) or @tls_key_editing}
                  class="textarea textarea-bordered font-mono text-xs h-32 resize-y"
                  name="channel[tls_key_pem]"
                  placeholder={"-----BEGIN EC PRIVATE KEY-----\n...\n-----END EC PRIVATE KEY-----"}
                ></textarea>
                <p :for={msg <- Enum.map(@tls_form[:tls_key_pem].errors, &translate_error/1)}
                   class="mt-1 text-sm text-error flex gap-1 items-center">
                  <.icon name="hero-exclamation-circle" class="size-4 shrink-0" />{msg}
                </p>
                <p :if={is_nil(@channel.tls_key_pem) or @tls_key_editing}
                   class="text-xs text-base-content/50 mt-1">
                  Stored encrypted. Never shown again after saving.
                </p>
              </div>

              <%!-- CA Certificate (optional — mutual TLS) --%>
              <div class="form-control">
                <label class="label">
                  <span class="label-text">CA Certificate (PEM) — optional, mutual TLS only</span>
                </label>
                <textarea
                  class="textarea textarea-bordered font-mono text-xs h-24 resize-y"
                  name="channel[tls_ca_cert_pem]"
                  placeholder={"-----BEGIN CERTIFICATE-----\n(CA cert from connecting health system)\n-----END CERTIFICATE-----"}
                >{@channel.tls_ca_cert_pem}</textarea>
                <p class="text-xs text-base-content/50 mt-1">
                  Only needed when requiring clients to present a certificate (mTLS).
                  Provide the CA certificate of the connecting system.
                </p>
              </div>

              <div class="form-control">
                <label class="label cursor-pointer justify-start gap-3">
                  <input type="checkbox" class="toggle toggle-sm"
                         name="channel[tls_verify_peer]" value="true"
                         checked={@channel.tls_verify_peer} />
                  <span class="label-text">Require client certificate (mutual TLS)</span>
                </label>
              </div>
            </div>

            <div>
              <button type="submit" class="btn btn-sm btn-primary">Save TLS Config</button>
            </div>
          </.form>
        </div>
      </div>
      <% end %>

      <%!-- Alerting --%>
      <div class="card bg-base-100 border border-base-300">
        <div class="card-body p-5">
          <h3 class="font-semibold mb-1">Alerting</h3>
          <p class="text-sm text-base-content/50 mb-4">
            Send an alert when consecutive failures exceed the threshold.
            Alerts are suppressed during the cooldown window to prevent flooding.
          </p>

          <.form :if={@alert_form} for={@alert_form} phx-submit="save_alert" class="space-y-4">
            <div class="form-control">
              <label class="label cursor-pointer justify-start gap-3">
                <input type="checkbox" class="toggle toggle-sm toggle-error"
                       name="channel[alert_enabled]" value="true"
                       checked={@channel.alert_enabled} />
                <span class="label-text">Enable alerts</span>
              </label>
            </div>

            <div class="grid grid-cols-2 gap-3">
              <div class="form-control">
                <label class="label"><span class="label-text">Consecutive failures threshold</span></label>
                <input type="number" class="input input-bordered input-sm" min="1"
                       name="channel[alert_threshold]" value={@channel.alert_threshold} />
              </div>
              <div class="form-control">
                <label class="label"><span class="label-text">Cooldown (minutes)</span></label>
                <input type="number" class="input input-bordered input-sm" min="1"
                       name="channel[alert_cooldown_minutes]" value={@channel.alert_cooldown_minutes} />
              </div>
            </div>

            <div class="form-control">
              <label class="label"><span class="label-text">Alert email (optional)</span></label>
              <input type="email" class="input input-bordered input-sm"
                     name="channel[alert_email]" value={@channel.alert_email}
                     placeholder="oncall@example.com" />
            </div>

            <div class="form-control">
              <label class="label"><span class="label-text">Webhook URL (optional)</span></label>
              <input type="text" class="input input-bordered input-sm font-mono"
                     name="channel[alert_webhook_url]" value={@channel.alert_webhook_url}
                     placeholder="https://hooks.slack.com/..." />
            </div>

            <div>
              <button type="submit" class="btn btn-sm btn-primary">Save Alert Config</button>
            </div>
          </.form>
        </div>
      </div>

      <%!-- Dispatch --%>
      <div class="card bg-base-100 border border-base-300">
        <div class="card-body p-5">
          <h3 class="font-semibold mb-1">Dispatch</h3>
          <p class="text-sm text-base-content/50 mb-1">
            Controls how many messages this channel may process simultaneously.
          </p>
          <div class="text-sm text-base-content/50 mb-4 space-y-1">
            <p>
              <span class="font-medium text-base-content/70">1 (default) — serial:</span>
              each message fully completes before the next begins. Delivery order is
              guaranteed to match receive order. Best for systems that require strict sequencing.
            </p>
            <p>
              <span class="font-medium text-base-content/70">2–20 — concurrent:</span>
              up to N messages processed at the same time. Useful when a channel receives
              from many simultaneous MLLP senders and the destination is slow (e.g. a 5-second
              HTTP webhook). Trade-off: ordering is not guaranteed across concurrent senders —
              two messages that arrive almost simultaneously may complete in either order.
              Within a single MLLP connection the ACK protocol still serializes sends, so
              per-connection ordering is always preserved.
            </p>
          </div>

          <.form :if={@dispatch_form} for={@dispatch_form} phx-submit="save_dispatch" class="flex items-end gap-4">
            <div class="form-control">
              <label class="label"><span class="label-text">Max concurrent messages</span></label>
              <input type="number" class="input input-bordered input-sm w-28" min="1" max="20"
                     name="channel[dispatch_concurrency]" value={@channel.dispatch_concurrency} />
            </div>
            <div>
              <button type="submit" class="btn btn-sm btn-primary">Save</button>
            </div>
          </.form>
        </div>
      </div>

      <%!-- Node Pinning (admin only) --%>
      <%= if @current_scope.user.is_admin do %>
      <div class="card bg-base-100 border border-base-300">
        <div class="card-body p-5">
          <h3 class="font-semibold mb-1">Node Pinning</h3>
          <p class="text-sm text-base-content/50 mb-4">
            Pin this channel's OTP tree to a specific cluster node — useful for network
            proximity or controlled rolling upgrades. When unpinned, Horde distributes
            the channel using consistent hashing. If the pinned node leaves the cluster,
            the channel falls back to uniform distribution until the node rejoins.
            If the channel is running, saving will restart it to apply the new placement.
          </p>

          <.form :if={@pin_form} for={@pin_form} phx-submit="save_pin" class="flex items-end gap-4">
            <div class="form-control">
              <label class="label"><span class="label-text">Pinned node</span></label>
              <select class="select select-bordered select-sm w-72" name="channel[pinned_node]">
                <option value="" selected={is_nil(@channel.pinned_node)}>— No pin (uniform distribution) —</option>
                <option :for={n <- @available_nodes} value={n} selected={@channel.pinned_node == n}>{n}</option>
              </select>
            </div>
            <div>
              <button type="submit" class="btn btn-sm btn-primary">Save</button>
            </div>
          </.form>
        </div>
      </div>
      <% end %>
    </div>

    <%!-- Transform modal (new only — edit redirects to full editor) --%>
    <div :if={@show_transform_modal} class="modal modal-open">
      <div class="modal-box max-w-lg">
        <h3 class="font-bold text-lg mb-4">New Transform Step</h3>
        <.form :if={@transform_form} for={@transform_form} phx-submit="save_transform" class="space-y-4">
          <input type="hidden" name={@transform_form[:channel_id].name} value={@channel.id} />
          <input type="hidden" name={@transform_form[:position].name} value={length(@channel.transform_steps)} />
          <div class="form-control">
            <label class="label"><span class="label-text">Step Name</span></label>
            <input type="text" class="input input-bordered" placeholder="e.g. Redact SSN"
                   name={@transform_form[:name].name} value={@transform_form[:name].value} />
          </div>
          <div class="form-control">
            <label class="label">
              <span class="label-text">Script</span>
              <span class="label-text-alt">You can edit this in the full editor after saving</span>
            </label>
            <textarea class="textarea textarea-bordered font-mono text-sm h-32"
                      name={@transform_form[:script].name}
                      placeholder={"msg = set(msg, \"PID.5.1\", \"REDACTED\")\nmsg"}>{@transform_form[:script].value}</textarea>
          </div>
          <div class="modal-action">
            <button type="button" phx-click="close_transform_modal" class="btn btn-ghost">Cancel</button>
            <button type="submit" class="btn btn-primary">Save</button>
          </div>
        </.form>
      </div>
      <div class="modal-backdrop" phx-click="close_transform_modal"></div>
    </div>

    <%!-- Destination modal --%>
    <div :if={@show_dest_modal} class="modal modal-open">
      <div class="modal-box max-w-lg">
        <h3 class="font-bold text-lg mb-4">
          {if @editing_dest, do: "Edit Destination", else: "New Destination"}
        </h3>
        <.form :if={@dest_form} for={@dest_form} phx-change="adapter_changed" phx-submit="save_destination" class="space-y-4">
          <input type="hidden" name={@dest_form[:channel_id].name} value={@channel.id} />
          <input :if={@editing_dest} type="hidden" name="destination_config[id]" value={@editing_dest.id} />
          <div class="form-control">
            <label class="label"><span class="label-text">Name</span></label>
            <input type="text" class="input input-bordered" placeholder="e.g. Audit SNS"
                   name={@dest_form[:name].name} value={@dest_form[:name].value} />
          </div>
          <div class="form-control">
            <label class="label"><span class="label-text">Adapter</span></label>
            <select class="select select-bordered" name={@dest_form[:adapter].name}>
              <option :for={{k, v} <- @adapter_labels} value={k}
                      selected={@selected_adapter == k}>{v}</option>
            </select>
          </div>

          <%!-- AWS SNS fields --%>
          <% cfg = @dest_form[:config].value || %{} %>
          <div :if={@selected_adapter == "aws_sns"} class="space-y-3">
            <input type="text" class="input input-bordered w-full" placeholder="Topic ARN"
                   name="destination_config[config][topic_arn]" value={cfg["topic_arn"]} />
            <input type="text" class="input input-bordered w-full" placeholder="AWS Region (e.g. us-east-1)"
                   name="destination_config[config][aws_region]" value={cfg["aws_region"]} />
            <input type="text" class="input input-bordered w-full" placeholder="Access Key ID (optional — use IAM roles instead)"
                   name="destination_config[config][aws_access_key_id]" value={cfg["aws_access_key_id"]} />
            <input type="password" class="input input-bordered w-full" placeholder="Secret Access Key (optional)"
                   name="destination_config[config][aws_secret_access_key]" value={cfg["aws_secret_access_key"]} />
          </div>

          <%!-- AWS SQS fields --%>
          <div :if={@selected_adapter == "aws_sqs"} class="space-y-3">
            <input type="text" class="input input-bordered w-full" placeholder="Queue URL"
                   name="destination_config[config][queue_url]" value={cfg["queue_url"]} />
            <input type="text" class="input input-bordered w-full" placeholder="AWS Region"
                   name="destination_config[config][aws_region]" value={cfg["aws_region"]} />
            <input type="text" class="input input-bordered w-full" placeholder="Access Key ID (optional)"
                   name="destination_config[config][aws_access_key_id]" value={cfg["aws_access_key_id"]} />
            <input type="password" class="input input-bordered w-full" placeholder="Secret Access Key (optional)"
                   name="destination_config[config][aws_secret_access_key]" value={cfg["aws_secret_access_key"]} />
          </div>

          <%!-- HTTP Webhook fields --%>
          <div :if={@selected_adapter == "http_webhook"} class="space-y-3">
            <input type="text" class="input input-bordered w-full" placeholder="URL"
                   name="destination_config[config][url]" value={cfg["url"]} />
            <textarea class="textarea textarea-bordered w-full font-mono text-xs h-20"
                      placeholder={"Authorization: Bearer token\nX-Custom-Header: value"}
                      name="destination_config[config][headers_raw]">{cfg["headers_raw"]}</textarea>
            <input type="number" class="input input-bordered w-full" placeholder="Timeout ms (default 10000)"
                   name="destination_config[config][timeout_ms]" value={cfg["timeout_ms"]} />
          </div>

          <%!-- MLLP Forward fields --%>
          <div :if={@selected_adapter == "mllp_forward"} class="space-y-3">
            <input type="text" class="input input-bordered w-full" placeholder="Host"
                   name="destination_config[config][host]" value={cfg["host"]} />
            <input type="number" class="input input-bordered w-full" placeholder="Port"
                   name="destination_config[config][port]" value={cfg["port"]} />
            <input type="number" class="input input-bordered w-full" placeholder="Timeout ms (default 10000)"
                   name="destination_config[config][timeout_ms]" value={cfg["timeout_ms"]} />
          </div>

          <%!-- Redis Queue fields --%>
          <div :if={@selected_adapter == "redis_queue"} class="space-y-3">
            <input type="text" class="input input-bordered w-full" placeholder="Redis URL (e.g. redis://localhost:6379)"
                   name="destination_config[config][redis_url]" value={cfg["redis_url"]} />
            <input type="text" class="input input-bordered w-full" placeholder="Key name"
                   name="destination_config[config][key]" value={cfg["key"]} />
            <select class="select select-bordered w-full" name="destination_config[config][type]">
              <option value="list" selected={cfg["type"] == "list"}>List (LPUSH)</option>
              <option value="stream" selected={cfg["type"] == "stream"}>Stream (XADD)</option>
            </select>
          </div>

          <%!-- File fields --%>
          <div :if={@selected_adapter == "file"} class="space-y-3">
            <input type="text" class="input input-bordered w-full" placeholder="File path (e.g. /var/log/hl7/audit.log)"
                   name="destination_config[config][path]" value={cfg["path"]} />
            <select class="select select-bordered w-full" name="destination_config[config][format]">
              <option value="raw" selected={cfg["format"] != "json"}>Raw HL7</option>
              <option value="json" selected={cfg["format"] == "json"}>JSON</option>
            </select>
          </div>

          <%!-- Sink fields --%>
          <div :if={@selected_adapter == "sink"} class="space-y-3">
            <p class="text-xs text-base-content/50">
              Messages are captured in-memory and inspectable at
              <.link navigate={~p"/tools/sinks"} class="link">Tools → Message Sinks</.link>.
            </p>
            <input type="text" class="input input-bordered w-full" placeholder="Sink name (e.g. audit, lab_feed)"
                   name="destination_config[config][name]" value={cfg["name"]} />
          </div>

          <div class="grid grid-cols-2 gap-3">
            <div class="form-control">
              <label class="label"><span class="label-text">Retry Attempts</span></label>
              <input type="number" class="input input-bordered" value={@dest_form[:retry_attempts].value || 3}
                     name={@dest_form[:retry_attempts].name} min="1" max="10" />
            </div>
            <div class="form-control">
              <label class="label"><span class="label-text">Base Retry ms</span></label>
              <input type="number" class="input input-bordered" value={@dest_form[:retry_base_ms].value || 1000}
                     name={@dest_form[:retry_base_ms].name} min="100" />
            </div>
          </div>

          <div class="modal-action">
            <button type="button" phx-click="close_dest_modal" class="btn btn-ghost">Cancel</button>
            <button type="submit" class="btn btn-primary">Save</button>
          </div>
        </.form>
      </div>
      <div class="modal-backdrop" phx-click="close_dest_modal"></div>
    </div>
    </Layouts.app>
    """
  end

  defp default_stats(channel) do
    %{
      processed_count: 0, failed_count: 0, last_error: nil, last_message_at: nil,
      paused: channel.paused, today_received: 0, today_processed: 0, today_failed: 0,
      retry_queue_depth: 0
    }
  end
end
