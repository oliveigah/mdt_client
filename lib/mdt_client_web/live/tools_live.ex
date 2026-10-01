defmodule MDTClientWeb.ToolsLive do
  @moduledoc "Picks the tool to work on."
  use MDTClientWeb, :live_view

  alias MDTClient.Tools

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Tools")
     |> assign(:tools, Tools.all())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} notices={@notices} update={@update}>
      <div class="flex min-h-0 flex-1 items-center justify-center overflow-y-auto p-6">
        <div class="w-full max-w-2xl">
          <header class="mb-6">
            <h1 class="text-lg font-semibold tracking-tight">
              Welcome back, {@current_scope.user.username}
            </h1>
            <p class="text-[13px] text-muted">Pick a tool to get to work.</p>
          </header>

          <div class="grid gap-3 sm:grid-cols-2">
            <.tool_card :for={tool <- @tools} tool={tool} />
          </div>

          <.link
            navigate={~p"/agents"}
            id="connect-agent"
            class="mt-5 flex items-center gap-3 rounded-xl border border-line-soft px-4 py-3 text-xs text-muted transition-colors hover:border-accent/40 hover:bg-panel hover:text-ink"
          >
            <.icon name="hero-command-line" class="size-4 text-accent" />
            <span class="flex-1">Connect an agent to save work in MDT through MCP.</span>
            <.icon name="hero-arrow-right" class="size-3.5" />
          </.link>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :tool, :map, required: true

  defp tool_card(assigns) do
    ~H"""
    <.link
      navigate={@tool.path}
      id={"tool-#{@tool.id}"}
      class={[
        "group flex h-full flex-col gap-3 rounded-xl border border-line bg-panel p-4",
        "transition-all hover:-translate-y-0.5 hover:border-accent/60 hover:shadow-lg hover:shadow-black/10 dark:hover:shadow-black/30",
        "focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-accent"
      ]}
    >
      <div class="flex items-center gap-3">
        <span class="flex size-9 items-center justify-center rounded-lg bg-deep text-accent transition-colors group-hover:bg-accent-soft">
          <.icon name={@tool.icon} class="size-5" />
        </span>
        <div class="min-w-0 flex-1">
          <div class="flex items-center gap-2">
            <h2 class="truncate text-sm font-semibold">{@tool.name}</h2>
            <span
              :if={@tool.status == :soon}
              class="rounded border border-warn/40 bg-warn-soft/50 px-1.5 py-0.5 text-[10px] font-medium uppercase tracking-wide text-warn"
            >
              Soon
            </span>
          </div>
          <p class="truncate text-xs text-muted">{@tool.tagline}</p>
        </div>
      </div>

      <p class="text-[13px] leading-relaxed text-muted">{@tool.description}</p>

      <div class="mt-auto flex items-center gap-1.5 pt-1 text-xs text-faint transition-colors group-hover:text-accent">
        Open
        <.icon
          name="hero-arrow-right"
          class="size-3.5 transition-transform group-hover:translate-x-0.5"
        />
      </div>
    </.link>
    """
  end
end
