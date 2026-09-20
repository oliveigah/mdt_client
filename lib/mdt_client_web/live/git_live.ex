defmodule MDTClientWeb.GitLive do
  @moduledoc "Placeholder for the git GUI, which has not been built yet."
  use MDTClientWeb, :live_view

  alias MDTClient.Tools

  @impl true
  def mount(_params, _session, socket) do
    tool = Tools.fetch!(:git)

    {:ok,
     socket
     |> assign(:page_title, tool.name)
     |> assign(:tool, tool)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} tool={@tool}>
      <div class="flex min-h-0 flex-1 items-center justify-center p-6">
        <div class="max-w-sm text-center">
          <span class="mx-auto mb-4 flex size-11 items-center justify-center rounded-xl border border-line bg-panel text-muted">
            <.icon name={@tool.icon} class="size-5" />
          </span>
          <h1 class="text-base font-semibold">{@tool.name}</h1>
          <p class="mt-1.5 text-[13px] leading-relaxed text-muted">{@tool.description}</p>
          <p class="mt-4 text-xs text-faint">Not built yet — the HTTP client comes first.</p>
          <.button navigate={~p"/tools/http"} variant="secondary" class="mt-5">
            <.icon name="hero-bolt" class="size-4 text-accent" /> Open HTTP Client
          </.button>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
