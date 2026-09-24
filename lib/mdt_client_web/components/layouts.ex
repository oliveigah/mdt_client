defmodule MDTClientWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use MDTClientWeb, :html

  alias MDTClient.Tools
  alias MDTClientWeb.Notices

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders the app shell: a thin title bar plus a full height work area.

  Pass `chrome={false}` for standalone screens (like the login page) that own
  the whole window.

  ## Examples

      <Layouts.app flash={@flash} current_scope={@current_scope} tool={@tool}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  attr :tool, :map, default: nil, doc: "the tool currently open, see `MDTClient.Tools`"
  attr :chrome, :boolean, default: true, doc: "renders the title bar"
  attr :notices, :list, default: [], doc: "the notices to float, see `MDTClientWeb.Notices`"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="relative flex h-full flex-col overflow-hidden bg-app text-ink">
      <header
        :if={@chrome}
        class="flex h-9 shrink-0 items-center gap-2 border-b border-line-soft bg-panel px-2.5"
      >
        <.link
          navigate={~p"/tools"}
          class="flex items-center gap-2 rounded px-1.5 py-1 text-accent transition-colors hover:bg-hover"
          title="All tools"
        >
          <.logo class="size-4" />
          <span class="text-[13px] font-semibold tracking-wide text-ink">MDT</span>
        </.link>

        <div class="mx-1 h-4 w-px bg-line"></div>

        <.tool_switcher current={@tool} />

        <div class="flex-1"></div>

        <.theme_toggle />

        <div class="mx-1 h-4 w-px bg-line"></div>

        <div :if={@current_scope} class="flex items-center gap-2">
          <span class="flex size-6 items-center justify-center rounded-full bg-accent-soft text-[10px] font-semibold text-accent">
            {@current_scope.user.initials}
          </span>
          <span class="hidden text-xs text-muted sm:inline">{@current_scope.user.username}</span>
          <.link
            navigate={~p"/transfer"}
            id="transfer-link"
            title="Export and import"
            class="flex size-7 items-center justify-center rounded text-muted transition-colors hover:bg-hover hover:text-ink"
          >
            <.icon name="hero-arrows-right-left" class="size-4" />
          </.link>
          <.link
            href={~p"/logout"}
            method="delete"
            title="Lock and sign out"
            class="flex size-7 items-center justify-center rounded text-muted transition-colors hover:bg-hover hover:text-bad"
          >
            <.icon name="hero-arrow-left-start-on-rectangle" class="size-4" />
          </.link>
        </div>
      </header>

      <main class="flex min-h-0 flex-1 flex-col">
        {render_slot(@inner_block)}
      </main>

      <.flash_group flash={@flash} />
      <.notice_group notices={@notices} />
    </div>
    """
  end

  @doc """
  Switches between tools, naming every one of them and marking the one open.
  """
  attr :current, :map, default: nil, doc: "the tool currently open, if any"

  def tool_switcher(assigns) do
    ~H"""
    <nav
      id="tool-switcher"
      aria-label="Tools"
      class="flex items-center gap-0.5"
    >
      <.link
        :for={tool <- Tools.all()}
        id={"tool-switch-#{tool.id}"}
        navigate={tool.path}
        aria-current={@current && @current.id == tool.id && "page"}
        class={[
          "group flex h-6 items-center gap-1.5 rounded px-2 text-xs transition-colors",
          if(@current && @current.id == tool.id,
            do: "bg-active font-medium text-ink",
            else: "text-muted hover:bg-hover hover:text-ink"
          )
        ]}
      >
        <.icon
          name={tool.icon}
          class={[
            "size-3.5 transition-colors",
            if(@current && @current.id == tool.id,
              do: "text-accent",
              else: "text-faint group-hover:text-muted"
            )
          ]}
        />
        {tool.name}
      </.link>
    </nav>
    """
  end

  @doc """
  Switches between the dark theme, the light theme and the system preference.

  The choice is applied and persisted by the script in `root.html.heex`; which
  segment reads as active is derived from the `data-theme` and
  `data-theme-source` attributes it sets on `<html>`.
  """
  attr :class, :any, default: nil

  def theme_toggle(assigns) do
    assigns =
      assign(assigns, :themes, [
        {"system", "hero-computer-desktop-micro", "Follow the system theme",
         "[[data-theme-source=system]_&]:bg-active [[data-theme-source=system]_&]:text-ink"},
        {"light", "hero-sun-micro", "Light theme",
         "[[data-theme-source=user][data-theme=light]_&]:bg-active [[data-theme-source=user][data-theme=light]_&]:text-ink"},
        {"dark", "hero-moon-micro", "Dark theme",
         "[[data-theme-source=user][data-theme=dark]_&]:bg-active [[data-theme-source=user][data-theme=dark]_&]:text-ink"}
      ])

    ~H"""
    <div class={["flex items-center gap-0.5 rounded-md border border-line bg-deep p-0.5", @class]}>
      <button
        :for={{theme, icon, label, active_class} <- @themes}
        type="button"
        phx-click={JS.dispatch("phx:set-theme") |> JS.push("set_theme", value: %{theme: theme})}
        data-phx-theme={theme}
        title={label}
        aria-label={label}
        class={[
          "flex size-5 cursor-pointer items-center justify-center rounded text-faint transition-colors hover:text-ink",
          active_class
        ]}
      >
        <.icon name={icon} class="size-3.5" />
      </button>
    </div>
    """
  end

  @doc """
  The MDT mark: connected modules forming a compact M.
  """
  attr :class, :any, default: "size-5"

  def logo(assigns) do
    ~H"""
    <svg viewBox="0 0 24 24" fill="none" aria-hidden="true" class={@class}>
      <path
        d="M4.25 18V7L12 11.6V18"
        stroke="var(--color-accent)"
        stroke-width="4"
        stroke-linecap="round"
        stroke-linejoin="round"
      />
      <path
        d="M12 11.6L19.75 7V18"
        stroke="var(--color-ok)"
        stroke-width="4"
        stroke-linecap="round"
        stroke-linejoin="round"
      />
    </svg>
    """
  end

  @doc """
  Floats the notices raised through `MDTClientWeb.Notices` in the bottom left
  corner, the ones waiting to be dismissed ahead of the ones leaving on their own.

  The padding stands in for the corner offset so the cards' shadows are not
  clipped when a long stack has to scroll.
  """
  attr :notices, :list, required: true

  def notice_group(assigns) do
    {persistent, passing} = Enum.split_with(assigns.notices, &Notices.persistent?/1)
    assigns = assign(assigns, :notices, persistent ++ passing)

    ~H"""
    <div
      :if={@notices != []}
      id="notices"
      aria-live="polite"
      class="pointer-events-none fixed bottom-0 left-0 z-50 flex max-h-[calc(100vh-2.25rem)] w-[25.5rem] max-w-full flex-col gap-2 overflow-y-auto p-3"
    >
      <.notice :for={notice <- @notices} notice={notice} />
    </div>
    """
  end

  attr :notice, :map, required: true

  defp notice(assigns) do
    assigns = assign(assigns, :persistent?, Notices.persistent?(assigns.notice))

    ~H"""
    <div
      id={"notice-#{@notice.id}"}
      role={if @persistent?, do: "alert", else: "status"}
      phx-hook={if not @persistent?, do: "NoticeTimer"}
      data-notice-id={@notice.id}
      data-timeout={if not @persistent?, do: "6000"}
      class={[
        "pointer-events-auto flex shrink-0 items-start gap-2.5 rounded-lg border bg-panel px-3 py-2.5",
        "shadow-lg shadow-black/10 dark:shadow-black/40",
        "transition duration-150 ease-out motion-safe:starting:translate-y-1.5 starting:opacity-0",
        notice_border(@notice.kind)
      ]}
    >
      <.icon
        name={notice_icon(@notice.kind)}
        class={["mt-px size-4 shrink-0", notice_tone(@notice.kind)]}
      />
      <div class="min-w-0 flex-1">
        <div class="flex items-baseline gap-2">
          <p class={["min-w-0 flex-1 text-[11px] font-semibold", notice_tone(@notice.kind)]}>
            {@notice.title}
          </p>
          <span
            :if={@notice.source}
            class="max-w-[40%] shrink-0 truncate font-mono text-[10px] text-faint"
          >
            {@notice.source}
          </span>
        </div>
        <pre
          :if={@notice.body not in [nil, ""]}
          class={[
            "mt-0.5 max-h-40 overflow-auto whitespace-pre-wrap break-words font-mono text-[11px] leading-relaxed",
            if(@persistent?, do: "text-ink/90", else: "text-muted")
          ]}
          phx-no-curly-interpolation
        ><%= @notice.body %></pre>
      </div>
      <button
        type="button"
        id={"dismiss-notice-#{@notice.id}"}
        phx-click="dismiss_notice"
        phx-value-id={@notice.id}
        title="Dismiss"
        aria-label="Dismiss"
        class="flex size-5 shrink-0 cursor-pointer items-center justify-center rounded text-faint transition-colors hover:bg-hover hover:text-ink"
      >
        <.icon name="hero-x-mark" class="size-3.5" />
      </button>
    </div>
    """
  end

  defp notice_icon(:success), do: "hero-check-circle"
  defp notice_icon(:info), do: "hero-information-circle"
  defp notice_icon(:warning), do: "hero-exclamation-triangle"
  defp notice_icon(:error), do: "hero-exclamation-circle"

  defp notice_tone(:success), do: "text-ok"
  defp notice_tone(:info), do: "text-accent"
  defp notice_tone(:warning), do: "text-warn"
  defp notice_tone(:error), do: "text-bad"

  defp notice_border(:success), do: "border-ok/30"
  defp notice_border(:info), do: "border-accent/40"
  defp notice_border(:warning), do: "border-warn/40"
  defp notice_border(:error), do: "border-bad/40"

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div
      id={@id}
      aria-live="polite"
      class="pointer-events-none fixed bottom-3 right-3 z-50 flex w-80 flex-col gap-2"
    >
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title="We can't reach the app"
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Attempting to reconnect
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title="Something went wrong!"
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Attempting to reconnect
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end
end
