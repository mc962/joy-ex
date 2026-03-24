defmodule JoyWeb.Layouts do
  @moduledoc """
  Application layout with sidebar navigation.

  The `app/1` component renders the full shell: fixed left sidebar, top header bar,
  and scrollable main content area. All LiveViews use this layout.
  """

  use JoyWeb, :html

  embed_templates "layouts/*"

  attr :flash, :map, required: true
  attr :current_scope, :any, default: nil
  attr :page_title, :string, default: nil
  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="flex h-screen overflow-hidden bg-base-200">
      <%!-- Sidebar --%>
      <nav class="w-60 shrink-0 flex flex-col border-r border-base-300 bg-base-100">
        <%!-- Branding --%>
        <div class="h-16 flex items-center gap-3 px-5 border-b border-base-300">
          <div class="flex items-center justify-center w-8 h-8 rounded-lg bg-primary">
            <.icon name="hero-signal" class="w-4 h-4 text-primary-content" />
          </div>
          <div>
            <p class="text-sm font-bold leading-tight text-base-content">Joy HL7</p>
            <p class="text-xs text-base-content/50 leading-tight">Integration Engine</p>
          </div>
        </div>

        <%!-- Nav links --%>
        <div class="flex-1 px-3 py-4 space-y-1 overflow-y-auto">
          <p class="px-2 mb-2 text-xs font-semibold uppercase tracking-widest text-base-content/40">
            Main
          </p>
          <.nav_link icon="hero-squares-2x2" label="Dashboard" href={~p"/"} />
          <.nav_link icon="hero-arrows-right-left" label="Channels" href={~p"/channels"} />
          <.nav_link icon="hero-building-office-2" label="Organizations" href={~p"/organizations"} />

          <p class="px-2 mt-6 mb-2 text-xs font-semibold uppercase tracking-widest text-base-content/40">
            Admin
          </p>
          <.nav_link icon="hero-users" label="Users" href={~p"/users"} />
          <.nav_link icon="hero-clipboard-document-list" label="Audit Log" href={~p"/audit"} />
          <.nav_link icon="hero-chart-bar" label="Live Metrics" href="/dev/dashboard" external />

          <p class="px-2 mt-6 mb-2 text-xs font-semibold uppercase tracking-widest text-base-content/40">
            Tools
          </p>
          <.nav_link icon="hero-paper-airplane" label="MLLP Client" href={~p"/tools/mllp-client"} />
          <.nav_link icon="hero-inbox" label="Message Sinks" href={~p"/tools/sinks"} />
          <.nav_link icon="hero-archive-box-arrow-down" label="Log Retention" href={~p"/tools/retention"} />
        </div>

        <%!-- Footer --%>
        <div class="p-4 border-t border-base-300">
          <div class="flex items-center gap-2 text-xs text-base-content/40">
            <.icon name="hero-server" class="w-3.5 h-3.5" />
            <span>HL7 v2.x Engine</span>
          </div>
        </div>
      </nav>

      <%!-- Main area --%>
      <div class="flex-1 flex flex-col min-w-0 overflow-hidden">
        <%!-- Top bar --%>
        <header class="h-16 shrink-0 flex items-center justify-between px-6 border-b border-base-300 bg-base-100">
          <h1 class="text-base font-semibold text-base-content truncate">
            {@page_title || "Joy HL7 Engine"}
          </h1>
          <div class="flex items-center gap-3">
            <.theme_toggle />
            <div class="flex items-center gap-1">
              <.link
                :if={@current_scope}
                href={~p"/users/settings"}
                class="btn btn-ghost btn-sm text-base-content/70"
              >
                {@current_scope.user.email}
              </.link>
              <.link
                :if={@current_scope}
                href={~p"/users/log-out"}
                method="delete"
                class="btn btn-ghost btn-sm"
              >
                Log out
              </.link>
              <.link
                :if={!@current_scope}
                href={~p"/users/log-in"}
                class="btn btn-ghost btn-sm"
              >
                Log in
              </.link>
              <.link
                :if={!@current_scope}
                href={~p"/users/register"}
                class="btn btn-primary btn-sm"
              >
                Sign up
              </.link>
            </div>
          </div>
        </header>

        <%!-- Scrollable content --%>
        <main class="flex-1 overflow-y-auto p-6">
          {render_slot(@inner_block)}
        </main>
      </div>
    </div>

    <.flash_group flash={@flash} />
    """
  end

  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :href, :string, required: true
  attr :external, :boolean, default: false

  defp nav_link(%{external: true} = assigns) do
    ~H"""
    <a
      href={@href}
      target="_blank"
      class="flex items-center gap-2.5 px-2 py-2 rounded-lg text-sm text-base-content/70 hover:text-base-content hover:bg-base-200 transition-colors group"
    >
      <.icon name={@icon} class="w-4 h-4 shrink-0 text-base-content/50 group-hover:text-base-content/80 transition-colors" />
      {@label}
    </a>
    """
  end

  defp nav_link(assigns) do
    ~H"""
    <.link
      navigate={@href}
      class="flex items-center gap-2.5 px-2 py-2 rounded-lg text-sm text-base-content/70 hover:text-base-content hover:bg-base-200 transition-colors group"
    >
      <.icon name={@icon} class="w-4 h-4 shrink-0 text-base-content/50 group-hover:text-base-content/80 transition-colors" />
      {@label}
    </.link>
    """
  end

  attr :flash, :map, required: true
  attr :id, :string, default: "flash-group"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title="Connection lost"
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Attempting to reconnect
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title="Something went wrong"
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Attempting to reconnect
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  def theme_toggle(assigns) do
    ~H"""
    <div class="flex items-center border border-base-300 bg-base-200 rounded-full p-0.5 gap-0.5">
      <button
        class="p-1.5 rounded-full hover:bg-base-300 transition-colors"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
        title="Light mode"
      >
        <.icon name="hero-sun-micro" class="size-3.5 text-base-content/60" />
      </button>
      <button
        class="p-1.5 rounded-full hover:bg-base-300 transition-colors"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
        title="Dark mode"
      >
        <.icon name="hero-moon-micro" class="size-3.5 text-base-content/60" />
      </button>
    </div>
    """
  end
end
