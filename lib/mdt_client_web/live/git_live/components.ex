defmodule MDTClientWeb.GitLive.Components do
  @moduledoc """
  The panels, menus and dialogs of the Git workspace.

  Everything here is a pure function of the tab it is given, so the LiveView
  stays a coordinator: it owns repository handles, snapshots and commands, and
  this module owns how they look.
  """
  use MDTClientWeb, :html

  alias MDTClient.Git.FileChange
  alias MDTClient.Git.Operation
  alias MDTClientWeb.GitLive.Graph.Layout

  @row_height 28
  @lane_width 16
  # The branch column only appears when the panel has room for it.
  @ref_column 168
  # Beyond this the graph column would push the commit text off screen, so the
  # extra lanes are drawn but clipped rather than widening every row.
  @visible_lanes 12

  @doc "The height of one commit row, in pixels."
  def row_height, do: @row_height

  defp lane_width, do: @lane_width
  defp visible_lanes, do: @visible_lanes
  defp ref_column_style, do: "width: #{@ref_column}px"
  defp graph_column_style(lanes), do: "width: #{max(lanes, 1) * @lane_width}px"

  ## Repository tabs

  attr :tabs, :list, required: true
  attr :active_id, :string, default: nil
  attr :tab, :map, default: nil
  attr :opening, :string, default: nil

  def tab_bar(assigns) do
    ~H"""
    <div id="git-tab-bar" class="flex h-9 shrink-0 items-stretch border-b border-line-soft bg-panel">
      <div id="git-tabs" role="tablist" class="flex min-w-0 flex-1 items-stretch overflow-x-auto">
        <div
          :for={tab <- @tabs}
          class={[
            "group flex shrink-0 items-center border-r border-line-soft transition-colors",
            if(tab.id == @active_id, do: "bg-deep", else: "hover:bg-hover")
          ]}
        >
          <button
            type="button"
            id={"git-tab-#{tab.id}"}
            role="tab"
            aria-selected={to_string(tab.id == @active_id)}
            phx-click="select_tab"
            phx-value-id={tab.id}
            class="flex cursor-pointer items-center gap-2 py-1 pl-3 pr-1.5 text-left"
          >
            <.icon
              name="hero-folder"
              class={["size-3.5", if(tab.id == @active_id, do: "text-accent", else: "text-faint")]}
            />
            <span class="flex min-w-0 flex-col leading-tight">
              <span class={[
                "max-w-40 truncate text-xs",
                if(tab.id == @active_id, do: "text-ink", else: "text-muted")
              ]}>
                {tab.name}
              </span>
              <span class="max-w-40 truncate font-mono text-[10px] text-faint">
                {head_label(tab)}
              </span>
            </span>
            <.icon
              :if={tab.pending}
              name="hero-arrow-path"
              class="size-3 text-accent motion-safe:animate-spin"
            />
          </button>
          <button
            type="button"
            id={"git-close-tab-#{tab.id}"}
            phx-click="close_tab"
            phx-value-id={tab.id}
            title={"Close #{tab.name}"}
            aria-label={"Close #{tab.name}"}
            class="mr-1.5 flex size-5 cursor-pointer items-center justify-center rounded text-faint opacity-0 transition-all hover:bg-active hover:text-ink focus:opacity-100 focus-visible:outline-2 focus-visible:outline-accent group-hover:opacity-100"
          >
            <.icon name="hero-x-mark" class="size-3" />
          </button>
        </div>
      </div>

      <button
        type="button"
        id="git-open-folder"
        phx-hook=".OpenFolder"
        title="Open a repository folder"
        aria-label="Open a repository folder"
        class="flex w-9 shrink-0 cursor-pointer items-center justify-center border-l border-line-soft text-muted transition-colors hover:bg-hover hover:text-ink focus-visible:outline-2 focus-visible:-outline-offset-2 focus-visible:outline-accent"
      >
        <.icon :if={is_nil(@opening)} name="hero-plus" class="size-4" />
        <.icon
          :if={@opening}
          name="hero-arrow-path"
          class="size-4 text-accent motion-safe:animate-spin"
        />
      </button>

      <.ssh_agent :if={@tab} tab={@tab} />
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".OpenFolder">
      export default {
        mounted() {
          this.el.addEventListener("click", async (event) => {
            event.preventDefault()
            await this.pick()
          })
        },

        async pick() {
          // The desktop shell exposes the picker through the Tauri IPC. Outside it
          // — a plain browser — there is nothing to call, so the app asks for a path.
          const dialog = window.__TAURI__?.dialog
          const invoke = window.__TAURI_INTERNALS__?.invoke || window.__TAURI__?.core?.invoke

          if (!dialog && !invoke) {
            return this.pushEvent("folder_dialog_unavailable", {
              reason: "The native folder picker is only available in the desktop app.",
            })
          }

          const options = {
            directory: true,
            multiple: false,
            recursive: false,
            title: "Open a Git repository",
          }

          try {
            const selection = dialog
              ? await dialog.open(options)
              : await invoke("plugin:dialog|open", {options})
            const first = Array.isArray(selection) ? selection[0] : selection
            const path = first && typeof first === "object" ? first.path : first

            if (path) this.pushEvent("open_repository", {path})
          } catch (error) {
            this.pushEvent("folder_dialog_unavailable", {
              reason: `The folder picker could not be opened: ${error?.message || error}`,
            })
          }
        }
      }
    </script>
    """
  end

  ## SSH agent

  attr :tab, :map, required: true

  def ssh_agent(assigns) do
    ~H"""
    <div class="relative flex shrink-0 items-center border-l border-line-soft px-1.5">
      <button
        type="button"
        id="git-ssh-agent"
        phx-click="toggle_ssh"
        aria-haspopup="dialog"
        aria-expanded={to_string(@tab.ssh_open?)}
        title="SSH agent used by this repository"
        class={[
          "flex cursor-pointer items-center gap-1.5 rounded px-1.5 py-1 text-[11px] transition-colors",
          "focus-visible:outline-2 focus-visible:outline-accent",
          if(@tab.ssh_open?,
            do: "bg-active text-ink",
            else: "text-muted hover:bg-hover hover:text-ink"
          )
        ]}
      >
        <.icon
          name="hero-key"
          class={["size-3.5", if(@tab.ssh_mode == :custom, do: "text-accent", else: "text-faint")]}
        />
        <span class="hidden sm:inline">{ssh_label(@tab)}</span>
      </button>

      <div
        :if={@tab.ssh_open?}
        id="git-ssh-popover"
        role="dialog"
        aria-label="SSH agent"
        class="absolute right-0 top-9 z-40 w-80 rounded-lg border border-line bg-panel p-3 shadow-xl shadow-black/20 dark:shadow-black/50"
      >
        <p class="text-[11px] font-semibold uppercase tracking-wide text-muted">SSH agent</p>
        <p class="mt-1 text-[11px] leading-relaxed text-faint">
          Used for remote authentication, and for signing when this repository is
          configured to sign with SSH. The choice applies to this tab only.
        </p>

        <form id="git-ssh-form" phx-submit="save_ssh" class="mt-3 flex flex-col gap-2">
          <label class="flex cursor-pointer items-start gap-2 rounded-md border border-line-soft p-2 transition-colors hover:border-line">
            <input
              type="radio"
              name="mode"
              value="default"
              checked={@tab.ssh_mode == :default}
              class="mt-0.5 size-3.5 cursor-pointer accent-accent"
            />
            <span class="min-w-0">
              <span class="block text-xs text-ink">Application default</span>
              <span class="block text-[11px] text-faint">
                Inherit the agent from the environment MDT was started in.
              </span>
            </span>
          </label>

          <label class="flex cursor-pointer items-start gap-2 rounded-md border border-line-soft p-2 transition-colors hover:border-line">
            <input
              type="radio"
              name="mode"
              value="custom"
              checked={@tab.ssh_mode == :custom}
              class="mt-0.5 size-3.5 cursor-pointer accent-accent"
            />
            <span class="min-w-0 flex-1">
              <span class="block text-xs text-ink">Custom socket</span>
              <input
                type="text"
                name="socket"
                id="git-ssh-socket"
                value={@tab.ssh_socket}
                placeholder="/run/user/1000/keyring/ssh"
                class="mt-1.5 w-full rounded border border-line bg-deep px-2 py-1 font-mono text-[11px] text-ink outline-none transition-colors placeholder:text-faint focus:border-accent/60"
              />
            </span>
          </label>

          <p :if={@tab.ssh_error} id="git-ssh-error" class="text-[11px] text-bad">
            {@tab.ssh_error}
          </p>

          <div class="flex items-center justify-end gap-2">
            <.button type="button" phx-click="toggle_ssh" variant="ghost" class="px-2 py-1">
              Cancel
            </.button>
            <.button type="submit" variant="primary" class="px-2 py-1">Apply</.button>
          </div>
        </form>
      </div>
    </div>
    """
  end

  ## Empty state

  attr :error, :any, default: nil

  def empty_state(assigns) do
    ~H"""
    <div id="git-empty-state" class="flex min-h-0 flex-1 items-center justify-center p-6">
      <div class="w-full max-w-md text-center">
        <span class="mx-auto mb-4 flex size-11 items-center justify-center rounded-xl border border-line bg-panel text-muted">
          <.icon name="hero-code-bracket-square" class="size-5" />
        </span>
        <h1 class="text-base font-semibold">No repository open</h1>
        <p class="mt-1.5 text-[13px] leading-relaxed text-muted">
          Open a folder to browse its branches, walk its history and stage work.
          Every folder you open gets its own tab.
        </p>

        <.button id="git-empty-open" phx-hook=".OpenFolder" variant="primary" class="mt-5">
          <.icon name="hero-folder-open" class="size-4" /> Open folder
        </.button>

        <.error_notice :if={@error} id="git-open-error" error={@error} />
      </div>
    </div>
    """
  end

  @doc """
  The fallback used when the native picker cannot run, such as in a browser.

  It carries the reason so the failure is never silent, and it can be opened
  with repositories already in tabs, which the empty state cannot.
  """
  attr :reason, :string, default: nil
  attr :error, :any, default: nil
  attr :path, :string, default: ""

  def open_dialog(assigns) do
    ~H"""
    <div
      id="git-open-dialog"
      class="fixed inset-0 z-50 flex items-center justify-center p-6"
      role="dialog"
      aria-modal="true"
      aria-labelledby="git-open-dialog-title"
    >
      <div class="absolute inset-0 bg-black/50" phx-click="close_open_dialog"></div>
      <div class="relative w-full max-w-md rounded-xl border border-line bg-panel p-4 shadow-2xl shadow-black/30 dark:shadow-black/60">
        <div class="flex items-start gap-2.5">
          <span class="flex size-8 shrink-0 items-center justify-center rounded-lg border border-line bg-deep">
            <.icon name="hero-folder-open" class="size-4 text-accent" />
          </span>
          <div class="min-w-0 flex-1">
            <p id="git-open-dialog-title" class="text-[13px] font-semibold text-ink">
              Open a repository
            </p>
            <p
              :if={@reason}
              id="git-open-dialog-reason"
              class="mt-1 text-[11px] leading-relaxed text-muted"
            >
              {@reason}
            </p>
          </div>
          <button
            type="button"
            id="git-close-open-dialog"
            phx-click="close_open_dialog"
            title="Close"
            aria-label="Close"
            class="flex size-6 shrink-0 cursor-pointer items-center justify-center rounded text-faint transition-colors hover:bg-hover hover:text-ink"
          >
            <.icon name="hero-x-mark" class="size-4" />
          </button>
        </div>

        <form id="git-manual-open" phx-submit="open_repository" class="mt-3 flex items-center gap-2">
          <input
            type="text"
            name="path"
            value={@path}
            placeholder="/path/to/repository"
            aria-label="Repository path"
            phx-mounted={JS.focus()}
            class="w-full rounded-md border border-line bg-deep px-2.5 py-1.5 font-mono text-xs text-ink outline-none transition-colors placeholder:text-faint focus:border-accent/60"
          />
          <.button type="submit" variant="primary">Open</.button>
        </form>

        <.error_notice :if={@error} id="git-open-dialog-error" error={@error} class="mt-3" />

        <div class="mt-3 flex items-center justify-between gap-2">
          <p class="text-[11px] text-faint">Any folder inside the worktree works.</p>
          <.button id="git-retry-picker" phx-hook=".OpenFolder" variant="ghost" class="px-2 py-1">
            <.icon name="hero-arrow-path" class="size-3.5" /> Try the picker again
          </.button>
        </div>
      </div>
    </div>
    """
  end

  ## Branch panel

  attr :tab, :map, required: true

  def branch_panel(assigns) do
    assigns =
      assigns
      |> assign(:locals, branches(assigns.tab, :local))
      |> assign(:remotes, branches(assigns.tab, :remote))

    ~H"""
    <aside
      id="git-branches"
      phx-hook=".RowMenu"
      aria-label="Branches"
      class="flex w-[var(--git-branches-width,15rem)] min-w-0 shrink-0 flex-col bg-panel"
    >
      <div class="flex h-9 shrink-0 items-center gap-2 border-b border-line-soft px-2.5">
        <span class="text-[11px] font-semibold uppercase tracking-wide text-muted">Branches</span>
        <span class="rounded bg-deep px-1.5 py-0.5 font-mono text-[10px] text-faint">
          {length(@locals) + length(@remotes)}
        </span>
        <div class="flex-1"></div>
        <button
          type="button"
          id="git-create-branch"
          phx-click="prepare"
          phx-value-action="create_branch"
          title="Create a branch"
          aria-label="Create a branch"
          class="flex size-6 cursor-pointer items-center justify-center rounded text-faint transition-colors hover:bg-hover hover:text-ink focus-visible:outline-2 focus-visible:outline-accent"
        >
          <.icon name="hero-plus" class="size-3.5" />
        </button>
      </div>

      <div class="shrink-0 border-b border-line-soft p-2">
        <form id="git-branch-search" phx-change="filter_branches" class="relative" autocomplete="off">
          <.icon
            name="hero-magnifying-glass"
            class="pointer-events-none absolute left-2 top-1/2 size-3.5 -translate-y-1/2 text-faint"
          />
          <input
            type="text"
            name="filter"
            id="git-branch-filter"
            value={@tab.filter}
            placeholder="Filter branches"
            aria-label="Filter branches"
            phx-debounce="120"
            class="w-full rounded-md border border-line bg-deep py-1.5 pl-7 pr-2 text-xs text-ink outline-none transition-colors placeholder:text-faint focus:border-accent/60 focus:ring-2 focus:ring-accent/15"
          />
        </form>
      </div>

      <div class="min-h-0 flex-1 overflow-y-auto px-1.5 py-2">
        <p
          :if={@locals == [] and @remotes == []}
          id="git-branches-empty"
          class="px-2 py-6 text-center text-xs text-faint"
        >
          <%= if @tab.filter == "" do %>
            This repository has no branches yet.
          <% else %>
            No branch matches “{@tab.filter}”.
          <% end %>
        </p>

        <.branch_section
          :if={@locals != []}
          id="git-local-branches"
          title="Local"
          branches={@locals}
          tab={@tab}
        />
        <.branch_section
          :if={@remotes != []}
          id="git-remote-branches"
          title="Remote"
          branches={@remotes}
          tab={@tab}
        />
      </div>
    </aside>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".RowMenu">
      export default {
        mounted() {
          this.el.addEventListener("contextmenu", (event) => {
            const row = event.target.closest("[data-menu-kind]")
            if (!row) return

            event.preventDefault()
            this.openMenu(row, event.clientX, event.clientY)
          })

          // Arrow keys walk the list and the menu key opens the row actions, so
          // the panel is usable without a pointer.
          this.el.addEventListener("keydown", (event) => {
            const row = event.target.closest("[data-menu-kind]")
            if (!row) return

            if (event.key === "ContextMenu" || (event.key === "F10" && event.shiftKey)) {
              event.preventDefault()
              return this.openMenu(row)
            }

            const moves = {ArrowDown: 1, ArrowUp: -1}
            if (!(event.key in moves)) return

            const options = Array.from(this.el.querySelectorAll("[role=option]"))
            const current = options.indexOf(event.target.closest("[role=option]"))
            if (current < 0) return

            event.preventDefault()
            options[Math.min(options.length - 1, Math.max(0, current + moves[event.key]))]?.focus()
          })
        },

        openMenu(row, x, y) {
          this.pushEvent("open_menu", {kind: row.dataset.menuKind, id: row.dataset.menuId, x, y})
        }
      }
    </script>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :branches, :list, required: true
  attr :tab, :map, required: true

  defp branch_section(assigns) do
    ~H"""
    <div class="mb-1">
      <div class="flex items-center gap-1 px-1.5 py-1 text-[10px] font-semibold uppercase tracking-wider text-faint">
        <span class="min-w-0 flex-1 truncate">{@title}</span>
        <span class="font-mono normal-case">{length(@branches)}</span>
      </div>
      <div id={@id} role="listbox" aria-label={"#{@title} branches"}>
        <.branch_row :for={branch <- @branches} branch={branch} tab={@tab} />
      </div>
    </div>
    """
  end

  attr :branch, :map, required: true
  attr :tab, :map, required: true

  defp branch_row(assigns) do
    assigns = assign(assigns, :slug, slug(assigns.branch.full_name))

    ~H"""
    <div
      id={"git-branch-#{@slug}"}
      data-menu-kind="branch"
      data-menu-id={@branch.full_name}
      class={[
        "group relative flex items-center gap-1 rounded-md pl-1.5 pr-1 transition-colors",
        if(@tab.selected_branch == @branch.full_name, do: "bg-active", else: "hover:bg-hover")
      ]}
    >
      <button
        type="button"
        id={"git-select-branch-#{@slug}"}
        role="option"
        aria-selected={to_string(@tab.selected_branch == @branch.full_name)}
        phx-click="select_branch"
        phx-value-name={@branch.full_name}
        class="flex min-w-0 flex-1 cursor-pointer flex-col gap-0.5 py-1.5 text-left focus-visible:outline-2 focus-visible:-outline-offset-2 focus-visible:outline-accent"
      >
        <span class="flex w-full items-center gap-1.5">
          <.icon
            :if={@branch.current?}
            name="hero-check-circle-micro"
            class="size-3 shrink-0 text-ok"
          />
          <.icon
            :if={not @branch.current?}
            name={chip_icon(@branch)}
            class="size-3 shrink-0 text-faint"
          />
          <span class={[
            "min-w-0 flex-1 truncate text-xs",
            cond do
              @branch.current? -> "font-semibold text-ok"
              @branch.kind == :remote -> "text-muted"
              true -> "text-ink"
            end
          ]}>
            {@branch.name}
          </span>
          <span
            :if={@branch.ahead > 0}
            title={"#{@branch.ahead} ahead of upstream"}
            class="flex shrink-0 items-center font-mono text-[10px] text-ok"
          >
            <.icon name="hero-arrow-up-micro" class="size-2.5" />{@branch.ahead}
          </span>
          <span
            :if={@branch.behind > 0}
            title={"#{@branch.behind} behind upstream"}
            class="flex shrink-0 items-center font-mono text-[10px] text-warn"
          >
            <.icon name="hero-arrow-down-micro" class="size-2.5" />{@branch.behind}
          </span>
        </span>
        <span
          :if={@branch.upstream || @branch.symbolic_target}
          class="w-full truncate font-mono text-[10px] text-faint"
        >
          {@branch.symbolic_target || @branch.upstream}
        </span>
      </button>

      <button
        type="button"
        id={"git-branch-menu-button-#{@slug}"}
        phx-click="open_menu"
        phx-value-kind="branch"
        phx-value-id={@branch.full_name}
        aria-haspopup="menu"
        aria-expanded={to_string(menu_open?(@tab, :branch, @branch.full_name))}
        title={"Actions for #{@branch.name}"}
        aria-label={"Actions for #{@branch.name}"}
        class="flex size-5 shrink-0 cursor-pointer items-center justify-center rounded text-faint opacity-0 transition-all hover:bg-panel hover:text-ink focus:opacity-100 focus-visible:outline-2 focus-visible:outline-accent group-hover:opacity-100"
      >
        <.icon name="hero-ellipsis-vertical" class="size-3.5" />
      </button>
    </div>
    """
  end

  attr :branch, :map, required: true
  attr :tab, :map, required: true

  defp branch_menu(assigns) do
    assigns = assign(assigns, :slug, slug(assigns.branch.full_name))

    ~H"""
    <.context_menu
      id={"git-branch-menu-#{@slug}"}
      anchor={@tab.menu[:anchor] || "git-branch-menu-button-#{@slug}"}
      at={@tab.menu[:at]}
      label={"Actions for #{@branch.name}"}
    >
      <.menu_item
        :if={@branch.kind == :local}
        id={"git-menu-checkout-#{@slug}"}
        icon="hero-arrow-right-circle"
        disabled={@branch.current?}
        phx-click="checkout_branch"
        phx-value-name={@branch.name}
      >
        Check out
      </.menu_item>
      <.menu_item
        :if={@branch.kind == :remote}
        id={"git-menu-checkout-remote-#{@slug}"}
        icon="hero-arrow-down-on-square"
        phx-click="prepare"
        phx-value-action="checkout_remote"
        phx-value-name={@branch.name}
      >
        Check out as local branch
      </.menu_item>

      <.menu_item
        id={"git-menu-branch-from-#{@slug}"}
        icon="hero-plus"
        phx-click="prepare"
        phx-value-action="create_branch"
        phx-value-start={@branch.full_name}
      >
        Create branch from here
      </.menu_item>

      <.menu_item
        :if={@branch.kind == :local}
        id={"git-menu-rename-#{@slug}"}
        icon="hero-pencil-square"
        phx-click="prepare"
        phx-value-action="rename_branch"
        phx-value-name={@branch.name}
      >
        Rename…
      </.menu_item>

      <.menu_separator />

      <.menu_item
        id={"git-menu-merge-#{@slug}"}
        icon="hero-arrows-pointing-in"
        disabled={@branch.current? or @tab.snapshot.detached?}
        phx-click="request"
        phx-value-action="merge"
        phx-value-revision={@branch.full_name}
      >
        Merge into {current_label(@tab)}
      </.menu_item>
      <.menu_item
        id={"git-menu-rebase-#{@slug}"}
        icon="hero-arrow-path-rounded-square"
        disabled={@branch.current? or @tab.snapshot.detached?}
        phx-click="request"
        phx-value-action="rebase"
        phx-value-revision={@branch.full_name}
      >
        Rebase {current_label(@tab)} onto this
      </.menu_item>

      <.menu_separator />

      <.menu_item
        :if={@branch.kind == :local}
        id={"git-menu-delete-#{@slug}"}
        icon="hero-trash"
        danger
        disabled={@branch.current?}
        phx-click="request"
        phx-value-action="delete_branch"
        phx-value-name={@branch.name}
      >
        Delete branch
      </.menu_item>
      <.menu_item
        :if={@branch.kind == :remote and @branch.remote}
        id={"git-menu-delete-remote-#{@slug}"}
        icon="hero-trash"
        danger
        phx-click="request"
        phx-value-action="delete_remote_branch"
        phx-value-remote={@branch.remote}
        phx-value-name={remote_branch_name(@branch)}
      >
        Delete on {@branch.remote}
      </.menu_item>
    </.context_menu>
    """
  end

  ## Commit graph

  attr :tab, :map, required: true
  attr :limits, :list, required: true

  def graph_panel(assigns) do
    assigns =
      assigns
      |> assign(:rows, assigns.tab.graph.rows)
      |> assign(:lanes, min(assigns.tab.graph.lane_count, visible_lanes()))

    ~H"""
    <section id="git-graph" class="@container flex min-w-0 flex-1 flex-col bg-app">
      <div class="flex h-9 shrink-0 items-center gap-2 border-b border-line-soft bg-panel px-2.5">
        <span class="flex min-w-0 items-center gap-1.5">
          <.icon
            name={if @tab.snapshot.detached?, do: "hero-scissors", else: "hero-arrows-right-left"}
            class={[
              "size-3.5 shrink-0",
              if(@tab.snapshot.detached?, do: "text-warn", else: "text-ok")
            ]}
          />
          <span class="min-w-0 truncate font-mono text-xs text-ink">{head_label(@tab)}</span>
        </span>

        <span
          :if={@tab.snapshot.operation}
          class="shrink-0 rounded border border-warn/40 bg-warn-soft/40 px-1.5 py-0.5 text-[10px] font-semibold text-warn"
        >
          {operation_name(@tab.snapshot.operation)} in progress
        </span>

        <div class="flex-1"></div>

        <span
          :if={@tab.pending}
          id="git-operation-status"
          class="flex shrink-0 items-center gap-1.5 text-[11px] text-accent"
        >
          <.icon name="hero-arrow-path" class="size-3.5 motion-safe:animate-spin" />
          {@tab.pending_label}
        </span>

        <div class="flex shrink-0 items-center gap-0.5">
          <button
            type="button"
            id="git-fetch"
            phx-click="request"
            phx-value-action="fetch"
            disabled={not is_nil(@tab.pending)}
            title="Fetch and prune every remote"
            class={toolbar_button()}
          >
            <.icon name="hero-arrow-down-tray" class="size-3.5" /> Fetch
          </button>
          <button
            type="button"
            id="git-pull"
            phx-click="request"
            phx-value-action="pull"
            disabled={not is_nil(@tab.pending) or @tab.snapshot.detached?}
            title="Pull the current branch, fast-forward only"
            class={toolbar_button()}
          >
            <.icon name="hero-arrow-down-circle" class="size-3.5" /> Pull
          </button>
          <button
            type="button"
            id="git-push"
            phx-click="request"
            phx-value-action="push"
            disabled={not is_nil(@tab.pending) or @tab.snapshot.detached?}
            title="Push the current branch"
            class={toolbar_button()}
          >
            <.icon name="hero-arrow-up-circle" class="size-3.5" /> Push
          </button>
        </div>

        <div class="mx-0.5 h-4 w-px bg-line"></div>

        <form id="git-limit-form" phx-change="set_limit" class="flex shrink-0 items-center gap-1">
          <label for="git-graph-limit" class="text-[10px] uppercase tracking-wide text-faint">
            Commits
          </label>
          <select
            id="git-graph-limit"
            name="limit"
            class="cursor-pointer rounded border border-line bg-deep px-1.5 py-1 font-mono text-[11px] text-ink outline-none focus:border-accent/60"
          >
            <option :for={limit <- @limits} value={limit} selected={limit == @tab.limit}>
              {limit}
            </option>
          </select>
        </form>

        <button
          type="button"
          id="git-refresh"
          phx-click="request"
          phx-value-action="refresh"
          disabled={not is_nil(@tab.pending)}
          title="Refresh"
          aria-label="Refresh"
          class="flex size-6 shrink-0 cursor-pointer items-center justify-center rounded text-faint transition-colors hover:bg-hover hover:text-ink disabled:cursor-not-allowed disabled:opacity-40 focus-visible:outline-2 focus-visible:outline-accent"
        >
          <.icon name="hero-arrow-path" class="size-3.5" />
        </button>
      </div>

      <div
        :if={@rows != []}
        id="git-commit-columns"
        aria-hidden="true"
        class="flex h-6 shrink-0 items-center gap-2 border-b border-line-soft bg-panel/60 pl-2 pr-1 text-[10px] uppercase tracking-wider text-faint"
      >
        <span class="hidden shrink-0 truncate text-right @[44rem]:block" style={ref_column_style()}>
          Branch
        </span>
        <span class="shrink-0" style={graph_column_style(@lanes)}>Graph</span>
        <span class="min-w-0 flex-1 truncate">Commit</span>
        <span class="w-20 shrink-0 truncate text-right">Author</span>
        <span class="w-16 shrink-0 truncate text-right">When</span>
        <span class="w-14 shrink-0 truncate text-right">SHA</span>
        <span class="w-6 shrink-0"></span>
      </div>

      <div
        id="git-commits"
        phx-hook=".RowMenu"
        role="listbox"
        aria-label="Commits"
        class="min-h-0 flex-1 overflow-y-auto"
      >
        <p :if={@rows == []} id="git-commits-empty" class="px-3 py-8 text-center text-xs text-faint">
          This repository has no commits yet.
        </p>
        <.commit_row :for={row <- @rows} row={row} tab={@tab} lanes={@lanes} />
      </div>
    </section>
    """
  end

  attr :row, :map, required: true
  attr :tab, :map, required: true
  attr :lanes, :integer, required: true

  defp commit_row(assigns) do
    assigns = assign(assigns, :id, assigns.row.commit.id)

    ~H"""
    <div
      id={"git-commit-#{@id}"}
      data-menu-kind="commit"
      data-menu-id={@id}
      class={[
        "group relative flex items-center transition-colors",
        if(@tab.selected_commit == @id, do: "bg-active", else: "hover:bg-hover")
      ]}
      style={"height: #{row_height()}px"}
    >
      <button
        type="button"
        id={"git-select-commit-#{@id}"}
        role="option"
        aria-selected={to_string(@tab.selected_commit == @id)}
        phx-click="select_commit"
        phx-value-id={@id}
        class="flex h-full min-w-0 flex-1 cursor-pointer items-center gap-2 pl-2 pr-1 text-left focus-visible:outline-2 focus-visible:-outline-offset-2 focus-visible:outline-accent"
      >
        <%!-- Wide enough: refs get their own column beside the graph, as a
              desktop Git client lays them out. Narrow: they ride the summary. --%>
        <span
          class="hidden shrink-0 items-center justify-end gap-1 overflow-hidden @[44rem]:flex"
          style={ref_column_style()}
        >
          <.label_chips labels={@row.commit.labels} limit={2} />
        </span>

        <.graph_cell row={@row} lanes={@lanes} head={@tab.snapshot.head} />

        <span class="flex min-w-0 flex-1 items-center gap-1.5">
          <span class="flex shrink-0 items-center gap-1 @[44rem]:hidden">
            <.label_chips labels={@row.commit.labels} limit={1} compact />
          </span>
          <span class="min-w-0 truncate text-[13px] text-ink">{@row.commit.summary}</span>
        </span>

        <span
          class="w-20 shrink-0 truncate text-right text-[11px] text-muted"
          title={@row.commit.author_email}
        >
          {@row.commit.author_name}
        </span>
        <span
          class="w-16 shrink-0 text-right text-[11px] text-faint"
          title={absolute_time(@row.commit.authored_at)}
        >
          {relative_time(@row.commit.authored_at)}
        </span>
        <span class="w-14 shrink-0 text-right font-mono text-[11px] text-faint">
          {short_id(@id)}
        </span>
      </button>

      <button
        type="button"
        id={"git-commit-menu-button-#{@id}"}
        phx-click="open_menu"
        phx-value-kind="commit"
        phx-value-id={@id}
        aria-haspopup="menu"
        aria-expanded={to_string(menu_open?(@tab, :commit, @id))}
        title="Commit actions"
        aria-label={"Actions for commit #{short_id(@id)}"}
        class={[
          "mr-1 flex size-5 shrink-0 cursor-pointer items-center justify-center rounded transition-all",
          "hover:bg-panel hover:text-ink focus:opacity-100 focus-visible:outline-2 focus-visible:outline-accent",
          "group-hover:opacity-100",
          if(@tab.selected_commit == @id,
            do: "text-ink opacity-100",
            else: "text-faint opacity-0"
          )
        ]}
      >
        <.icon name="hero-ellipsis-vertical" class="size-3.5" />
      </button>
    </div>
    """
  end

  attr :row, :map, required: true
  attr :lanes, :integer, required: true
  attr :head, :string, default: nil

  defp graph_cell(assigns) do
    ~H"""
    <span
      class="shrink-0 overflow-hidden"
      style={graph_column_style(@lanes) <> "; height: #{row_height()}px"}
      aria-hidden="true"
    >
      <svg
        width={max(@lanes, 1) * lane_width()}
        height={row_height()}
        viewBox={"0 0 #{max(@lanes, 1) * lane_width()} #{row_height()}"}
        fill="none"
      >
        <path
          :for={{from, to, color} <- @row.through}
          d={through_path(from, to)}
          class={lane_color(color)}
          stroke="currentColor"
          stroke-width="2"
        />
        <path
          :for={{from, to, color} <- @row.incoming}
          d={incoming_path(from, to)}
          class={lane_color(color)}
          stroke="currentColor"
          stroke-width="2"
        />
        <path
          :for={{from, to, color} <- @row.outgoing}
          d={outgoing_path(from, to)}
          class={lane_color(color)}
          stroke="currentColor"
          stroke-width="2"
        />
        <circle
          cx={lane_center(@row.lane)}
          cy={div(row_height(), 2)}
          r={if @row.commit.id == @head, do: 5, else: 4}
          class={lane_color(@row.color)}
          fill="currentColor"
          stroke="var(--color-app)"
          stroke-width={if @row.commit.id == @head, do: 2, else: 0}
        />
      </svg>
    </span>
    """
  end

  attr :labels, :list, required: true
  attr :limit, :integer, default: nil, doc: "how many chips to draw before collapsing the rest"
  attr :compact, :boolean, default: false

  defp label_chips(assigns) do
    # Most important first, so a collapsed chip never hides the branch HEAD is on.
    labels = Enum.sort_by(assigns.labels, &{not &1.current?, &1.kind == :remote, &1.name})
    {shown, rest} = Enum.split(labels, assigns.limit || length(labels))
    assigns = assigns |> assign(:shown, shown) |> assign(:rest, rest)

    ~H"""
    <.label_chip :for={label <- @shown} label={label} compact={@compact} />
    <span
      :if={@rest != []}
      title={Enum.map_join(@rest, ", ", & &1.name)}
      class="shrink-0 rounded border border-line bg-deep px-1 py-px font-mono text-[10px] leading-4 text-faint"
    >
      +{length(@rest)}
    </span>
    """
  end

  attr :label, :map, required: true
  attr :compact, :boolean, default: false, doc: "drops the remote prefix when space is tight"

  defp label_chip(assigns) do
    ~H"""
    <span
      title={chip_title(@label)}
      class={[
        "flex min-w-0 shrink items-center gap-1 rounded border px-1 py-px font-mono text-[10px] leading-4",
        cond do
          @label.current? -> "border-ok/60 bg-ok-soft/60 text-ok"
          @label.kind == :remote -> "border-violet/50 bg-violet/10 text-violet"
          true -> "border-accent/50 bg-accent-soft/70 text-accent"
        end
      ]}
    >
      <.icon name={chip_icon(@label)} class="size-2.5 shrink-0" />
      <span
        :if={@label.kind == :remote and not is_nil(@label.remote) and not @compact}
        class="shrink-0 opacity-70"
      >
        {@label.remote}/
      </span>
      <span class="truncate">{chip_name(@label, @compact)}</span>
    </span>
    """
  end

  # A monitor for a branch that exists on this machine, a cloud for one that
  # only exists on a remote, and a tick for the branch HEAD is on.
  defp chip_icon(%{current?: true}), do: "hero-check-circle-micro"
  defp chip_icon(%{kind: :remote}), do: "hero-cloud-micro"
  defp chip_icon(_label), do: "hero-computer-desktop-micro"

  defp chip_name(%{kind: :remote} = label, _compact), do: remote_branch_name(label)
  defp chip_name(label, _compact), do: label.name

  defp chip_title(%{kind: :remote} = label), do: "Remote branch #{label.name}"
  defp chip_title(%{current?: true} = label), do: "Current branch #{label.name}"
  defp chip_title(label), do: "Local branch #{label.name}"

  attr :commit, :map, required: true
  attr :tab, :map, required: true

  defp commit_menu(assigns) do
    ~H"""
    <.context_menu
      id={"git-commit-menu-#{@commit.id}"}
      anchor={@tab.menu[:anchor] || "git-commit-menu-button-#{@commit.id}"}
      at={@tab.menu[:at]}
      label={"Actions for commit #{short_id(@commit.id)}"}
    >
      <.menu_item
        id={"git-menu-detach-#{@commit.id}"}
        icon="hero-arrow-right-circle"
        phx-click="request"
        phx-value-action="checkout_commit"
        phx-value-revision={@commit.id}
      >
        Check out this commit
      </.menu_item>
      <.menu_item
        id={"git-menu-branch-here-#{@commit.id}"}
        icon="hero-plus"
        phx-click="prepare"
        phx-value-action="create_branch"
        phx-value-start={@commit.id}
      >
        Create branch here
      </.menu_item>

      <.menu_separator />

      <.menu_item
        id={"git-menu-cherry-pick-#{@commit.id}"}
        icon="hero-sparkles"
        phx-click="request"
        phx-value-action="cherry_pick"
        phx-value-revision={@commit.id}
      >
        Cherry-pick commit
      </.menu_item>
      <.menu_item
        id={"git-menu-revert-#{@commit.id}"}
        icon="hero-arrow-uturn-left"
        phx-click="request"
        phx-value-action="revert"
        phx-value-revision={@commit.id}
      >
        Revert commit
      </.menu_item>
      <.menu_item
        id={"git-menu-commit-merge-#{@commit.id}"}
        icon="hero-arrows-pointing-in"
        disabled={@tab.snapshot.detached? or head?(@tab, @commit)}
        phx-click="request"
        phx-value-action="merge"
        phx-value-revision={@commit.id}
      >
        Merge into {current_label(@tab)}
      </.menu_item>
      <.menu_item
        id={"git-menu-commit-rebase-#{@commit.id}"}
        icon="hero-arrow-path-rounded-square"
        disabled={@tab.snapshot.detached? or head?(@tab, @commit)}
        phx-click="request"
        phx-value-action="rebase"
        phx-value-revision={@commit.id}
      >
        Rebase {current_label(@tab)} onto this
      </.menu_item>

      <.menu_separator />

      <.menu_item
        id={"git-menu-edit-message-#{@commit.id}"}
        icon="hero-pencil-square"
        disabled={@tab.snapshot.detached?}
        phx-click="prepare"
        phx-value-action="edit_message"
        phx-value-revision={@commit.id}
      >
        Edit commit message…
      </.menu_item>
      <.menu_item
        id={"git-menu-soft-reset-#{@commit.id}"}
        icon="hero-arrow-left-circle"
        disabled={@tab.snapshot.detached?}
        phx-click="request"
        phx-value-action="soft_reset"
        phx-value-revision={@commit.id}
      >
        Reset {current_label(@tab)} here, keep changes
      </.menu_item>
      <.menu_item
        id={"git-menu-hard-reset-#{@commit.id}"}
        icon="hero-exclamation-triangle"
        danger
        disabled={@tab.snapshot.detached?}
        phx-click="request"
        phx-value-action="hard_reset"
        phx-value-revision={@commit.id}
      >
        Reset {current_label(@tab)} here, discard changes
      </.menu_item>

      <.menu_separator />

      <.menu_item
        id={"git-menu-copy-sha-#{@commit.id}"}
        icon="hero-clipboard-document"
        phx-hook=".Copy"
        data-copy={@commit.id}
        phx-click="close_menu"
      >
        Copy commit SHA
      </.menu_item>
    </.context_menu>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".Copy">
      export default {
        mounted() {
          this.el.addEventListener("click", () => {
            navigator.clipboard?.writeText(this.el.dataset.copy || "")
          })
        }
      }
    </script>
    """
  end

  ## Context menus

  @doc """
  The open context menu, rendered once at the root of the page.

  Keeping it out of the scrolling panels means it is never clipped by them, and
  any control can open it by passing its own DOM id as the anchor.
  """
  attr :tab, :map, required: true

  def menu_overlay(assigns) do
    ~H"""
    <%= case menu_target(@tab) do %>
      <% {:branch, branch} -> %>
        <.branch_menu branch={branch} tab={@tab} />
      <% {:commit, commit} -> %>
        <.commit_menu commit={commit} tab={@tab} />
      <% nil -> %>
    <% end %>
    """
  end

  defp menu_target(%{menu: %{kind: :branch, id: id}} = tab) do
    case Enum.find(tab.snapshot.branches, &(&1.full_name == id)) do
      nil -> nil
      branch -> {:branch, branch}
    end
  end

  defp menu_target(%{menu: %{kind: :commit, id: id}} = tab) do
    case Enum.find(tab.snapshot.commits, &(&1.id == id)) do
      nil -> nil
      commit -> {:commit, commit}
    end
  end

  defp menu_target(_tab), do: nil

  attr :id, :string, required: true
  attr :anchor, :string, required: true
  attr :label, :string, required: true
  attr :at, :any, default: nil, doc: "the pointer position the menu was opened from"
  slot :inner_block, required: true

  defp context_menu(assigns) do
    ~H"""
    <div
      id={@id}
      phx-hook=".Menu"
      data-anchor={@anchor}
      data-x={@at && @at.x}
      data-y={@at && @at.y}
      role="menu"
      aria-label={@label}
      class="invisible fixed left-0 top-0 z-40 flex max-h-[calc(100vh-1rem)] w-60 flex-col overflow-y-auto rounded-lg border border-line bg-panel p-1 shadow-xl shadow-black/20 dark:shadow-black/50"
    >
      {render_slot(@inner_block)}
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".Menu">
      export default {
        mounted() {
          this.reposition()
          this.focusFirst()

          // No backdrop element: one would sit over the rows and swallow the next
          // right click, which the webview would then answer with its own menu.
          this.onDismiss = (event) => {
            if (this.el.contains(event.target)) return
            // A right click on another row belongs to the list hook, which moves
            // this menu there instead of closing it.
            if (event.type === "contextmenu" && event.target.closest("[data-menu-kind]")) return
            // Menu triggers toggle themselves; closing here first would reopen it.
            if (event.target.closest("[aria-haspopup=menu]")) return

            this.pushEvent("close_menu", {})
          }

          // A menu anchored to a row would drift away from it as the list scrolls.
          this.onScroll = () => this.pushEvent("close_menu", {})

          document.addEventListener("pointerdown", this.onDismiss, true)
          document.addEventListener("contextmenu", this.onDismiss, true)
          window.addEventListener("scroll", this.onScroll, {capture: true, passive: true})
          window.addEventListener("resize", this.onScroll)
        },

        updated() { this.reposition() },

        destroyed() {
          document.removeEventListener("pointerdown", this.onDismiss, true)
          document.removeEventListener("contextmenu", this.onDismiss, true)
          window.removeEventListener("scroll", this.onScroll, {capture: true})
          window.removeEventListener("resize", this.onScroll)
        },

        reposition() {
          // Parking the menu at 0,0 first reveals where its containing block starts
          // and the scale the interface is rendered at, so pointer coordinates keep
          // mapping to the right spot even when the window is zoomed.
          this.el.style.left = "0px"
          this.el.style.top = "0px"

          const origin = this.el.getBoundingClientRect()
          const scale = (this.el.offsetWidth && origin.width / this.el.offsetWidth) || 1
          const spot = this.spot(origin.width, origin.height)

          this.el.style.left = `${(spot.x - origin.left) / scale}px`
          this.el.style.top = `${(spot.y - origin.top) / scale}px`
          this.el.style.visibility = "visible"
        },

        // Where the top left corner should end up, in client coordinates.
        spot(width, height) {
          const margin = 8
          const lastX = Math.max(margin, window.innerWidth - width - margin)
          const lastY = Math.max(margin, window.innerHeight - height - margin)
          const x = parseFloat(this.el.dataset.x)
          const y = parseFloat(this.el.dataset.y)

          if (Number.isFinite(x) && Number.isFinite(y)) {
            // Hang off the cursor. A menu too tall for the room below slides up
            // just enough to fit rather than jumping above the click.
            return {x: x + width + margin > window.innerWidth ? Math.max(margin, x - width) : x,
                    y: Math.min(y, lastY)}
          }

          const anchor = document.getElementById(this.el.dataset.anchor)
          if (!anchor) return {x: lastX, y: margin}

          const rect = anchor.getBoundingClientRect()
          return {x: Math.min(Math.max(margin, rect.right - width), lastX),
                  y: Math.min(rect.bottom + 4, lastY)}
        },

        focusFirst() {
          this.items()[0]?.focus()
          this.el.addEventListener("keydown", (event) => {
            const items = this.items()
            const current = items.indexOf(document.activeElement)
            const moves = {ArrowDown: 1, ArrowUp: -1}

            if (event.key in moves) {
              event.preventDefault()
              const next = (current + moves[event.key] + items.length) % items.length
              items[Math.max(next, 0)]?.focus()
            } else if (event.key === "Home") {
              event.preventDefault()
              items[0]?.focus()
            } else if (event.key === "End") {
              event.preventDefault()
              items[items.length - 1]?.focus()
            }
          })
        },

        items() {
          return Array.from(this.el.querySelectorAll("[role=menuitem]:not([disabled])"))
        }
      }
    </script>
    """
  end

  attr :id, :string, default: nil
  attr :icon, :string, required: true
  attr :danger, :boolean, default: false
  attr :disabled, :boolean, default: false
  attr :rest, :global
  slot :inner_block, required: true

  defp menu_item(assigns) do
    ~H"""
    <button
      type="button"
      id={@id}
      role="menuitem"
      disabled={@disabled}
      class={[
        "flex cursor-pointer items-center gap-2 rounded px-2 py-1.5 text-left text-xs transition-colors",
        "focus:outline-none focus-visible:outline-none disabled:cursor-not-allowed disabled:opacity-40",
        if(@danger,
          do: "text-bad hover:bg-bad-soft/50 focus:bg-bad-soft/50",
          else: "text-ink hover:bg-hover focus:bg-hover"
        )
      ]}
      {@rest}
    >
      <.icon name={@icon} class="size-3.5 shrink-0 opacity-70" />
      <span class="min-w-0 truncate">{render_slot(@inner_block)}</span>
    </button>
    """
  end

  defp menu_separator(assigns) do
    ~H"""
    <div class="my-1 h-px bg-line-soft" role="separator"></div>
    """
  end

  ## Inspector

  attr :tab, :map, required: true

  def inspector_panel(assigns) do
    ~H"""
    <aside
      id="git-inspector"
      aria-label="Inspector"
      class="flex w-[var(--git-inspector-width,22rem)] min-w-0 shrink-0 flex-col bg-panel"
    >
      <div class="flex h-9 shrink-0 items-center gap-1 border-b border-line-soft px-2">
        <.panel_tab tab={@tab} name="commit" label="Commit" icon="hero-document-text" />
        <.panel_tab
          tab={@tab}
          name="changes"
          label="Changes"
          icon="hero-pencil-square"
          count={length(@tab.changes)}
        />
      </div>

      <div class="min-h-0 flex-1 overflow-y-auto">
        <.operation_banner :if={@tab.snapshot.operation} tab={@tab} />
        <.error_notice :if={@tab.error} id="git-error" error={@tab.error} class="m-2.5" />
        <.result_notice :if={@tab.result} result={@tab.result} />
        <.action_form :if={@tab.action} tab={@tab} />

        <%= cond do %>
          <% @tab.action -> %>
            <span class="sr-only">An action is being prepared.</span>
          <% @tab.panel == "changes" -> %>
            <.working_tree tab={@tab} />
          <% commit = selected_commit(@tab) -> %>
            <.commit_details tab={@tab} commit={commit} />
          <% true -> %>
            <.empty
              id="git-inspector-empty"
              icon="hero-cursor-arrow-rays"
              title="No commit selected"
              hint="Click a commit in the graph to inspect it, or right click it for actions."
            />
        <% end %>
      </div>
    </aside>
    """
  end

  attr :tab, :map, required: true
  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :icon, :string, required: true
  attr :count, :integer, default: 0

  defp panel_tab(assigns) do
    ~H"""
    <button
      type="button"
      id={"git-panel-#{@name}"}
      phx-click="set_panel"
      phx-value-panel={@name}
      aria-pressed={to_string(@tab.panel == @name)}
      class={[
        "flex cursor-pointer items-center gap-1.5 rounded px-2 py-1 text-[11px] transition-colors",
        "focus-visible:outline-2 focus-visible:outline-accent",
        if(@tab.panel == @name,
          do: "bg-active text-ink",
          else: "text-muted hover:bg-hover hover:text-ink"
        )
      ]}
    >
      <.icon name={@icon} class="size-3.5" />
      {@label}
      <span :if={@count > 0} class="font-mono text-[10px] text-accent">{@count}</span>
    </button>
    """
  end

  attr :tab, :map, required: true
  attr :commit, :map, required: true

  defp commit_details(assigns) do
    ~H"""
    <div id="git-commit-details" class="flex flex-col gap-3 p-2.5">
      <div>
        <div class="flex items-start gap-2">
          <p class="min-w-0 flex-1 text-[13px] font-semibold leading-snug text-ink">
            {@commit.summary}
          </p>
          <button
            type="button"
            id="git-commit-actions"
            phx-click="open_menu"
            phx-value-kind="commit"
            phx-value-id={@commit.id}
            phx-value-anchor="git-commit-actions"
            aria-haspopup="menu"
            aria-expanded={to_string(menu_open?(@tab, :commit, @commit.id))}
            class="flex shrink-0 cursor-pointer items-center gap-1 rounded border border-line px-1.5 py-0.5 text-[11px] text-muted transition-colors hover:bg-hover hover:text-ink focus-visible:outline-2 focus-visible:outline-accent"
          >
            Actions <.icon name="hero-chevron-down-micro" class="size-3" />
          </button>
        </div>
        <p class="mt-1 flex items-center gap-1.5 font-mono text-[11px] text-faint">
          <.icon name="hero-hashtag-micro" class="size-3" />
          <span class="select-all">{@commit.id}</span>
        </p>
      </div>

      <div :if={@commit.labels != []} class="flex flex-wrap gap-1">
        <.label_chips labels={@commit.labels} />
      </div>

      <pre
        :if={String.trim(@commit.body) != ""}
        id="git-commit-body"
        class="whitespace-pre-wrap break-words rounded-md border border-line-soft bg-deep p-2 font-mono text-[11px] leading-relaxed text-ink"
        phx-no-curly-interpolation
      ><%= String.trim_trailing(@commit.body) %></pre>

      <div class="flex flex-col gap-2 rounded-md border border-line-soft p-2">
        <.identity
          role="Author"
          name={@commit.author_name}
          email={@commit.author_email}
          at={@commit.authored_at}
        />
        <.identity
          :if={different_committer?(@commit)}
          role="Committer"
          name={@commit.committer_name}
          email={@commit.committer_email}
          at={@commit.committed_at}
        />
      </div>

      <div class="flex items-start gap-2 rounded-md border border-line-soft p-2">
        <.icon name={signature_icon(@commit)} class={["mt-px size-3.5", signature_color(@commit)]} />
        <div class="min-w-0">
          <p class={["text-[11px] font-medium", signature_color(@commit)]}>
            {signature_label(@commit.signature_status)}
          </p>
          <p :if={@commit.signature_signer} class="truncate font-mono text-[10px] text-faint">
            {@commit.signature_signer}
          </p>
        </div>
      </div>

      <div>
        <p class="mb-1 text-[10px] font-semibold uppercase tracking-wide text-muted">
          {parents_label(@commit)}
        </p>
        <p :if={@commit.parents == []} class="text-[11px] text-faint">
          A root commit, with no parents.
        </p>
        <div class="flex flex-wrap gap-1">
          <button
            :for={parent <- @commit.parents}
            type="button"
            id={"git-parent-#{@commit.id}-#{parent}"}
            phx-click="select_commit"
            phx-value-id={parent}
            disabled={not known_commit?(@tab, parent)}
            title={parent}
            class="cursor-pointer rounded border border-line bg-deep px-1.5 py-0.5 font-mono text-[10px] text-accent transition-colors hover:border-accent/60 hover:bg-hover disabled:cursor-not-allowed disabled:text-faint focus-visible:outline-2 focus-visible:outline-accent"
          >
            {short_id(parent)}
          </button>
        </div>
      </div>
    </div>
    """
  end

  attr :role, :string, required: true
  attr :name, :string, required: true
  attr :email, :string, required: true
  attr :at, :any, required: true

  defp identity(assigns) do
    ~H"""
    <div class="flex min-w-0 items-baseline gap-2">
      <span class="w-16 shrink-0 text-[10px] uppercase tracking-wide text-faint">{@role}</span>
      <span class="min-w-0 flex-1">
        <span class="block truncate text-[11px] text-ink">{@name}</span>
        <span class="block truncate font-mono text-[10px] text-muted">{@email}</span>
        <span class="block font-mono text-[10px] text-faint" title={relative_time(@at)}>
          {absolute_time(@at)}
        </span>
      </span>
    </div>
    """
  end

  ## Operation in progress

  attr :tab, :map, required: true

  def operation_banner(assigns) do
    assigns = assign(assigns, :operation, assigns.tab.snapshot.operation)

    ~H"""
    <div id="git-operation" class="m-2.5 rounded-md border border-warn/40 bg-warn-soft/25 p-2.5">
      <div class="flex items-center gap-1.5">
        <.icon name="hero-exclamation-triangle" class="size-3.5 shrink-0 text-warn" />
        <p class="text-xs font-semibold text-warn">
          {operation_name(@operation)} in progress
        </p>
        <span
          :if={@operation.current && @operation.total}
          class="ml-auto font-mono text-[10px] text-warn"
        >
          {@operation.current}/{@operation.total}
        </span>
      </div>

      <p class="mt-1 text-[11px] leading-relaxed text-muted">
        {operation_hint(@operation)}
      </p>

      <dl class="mt-1.5 flex flex-col gap-0.5 font-mono text-[10px] text-faint">
        <div :if={@operation.targets != []} class="flex gap-1.5">
          <dt class="shrink-0">target</dt>
          <dd class="min-w-0 truncate text-muted">
            {Enum.map_join(@operation.targets, ", ", &short_id/1)}
          </dd>
        </div>
        <div :if={@operation.original_head} class="flex gap-1.5">
          <dt class="shrink-0">was at</dt>
          <dd class="min-w-0 truncate text-muted">{short_id(@operation.original_head)}</dd>
        </div>
      </dl>

      <div class="mt-2 flex items-center gap-1.5">
        <.button
          id="git-operation-continue"
          phx-click="request"
          phx-value-action="continue"
          disabled={not continuable?(@operation) or not is_nil(@tab.pending)}
          variant="secondary"
          class="px-2 py-1 text-[11px]"
        >
          Continue
        </.button>
        <.button
          id="git-operation-skip"
          phx-click="request"
          phx-value-action="skip"
          disabled={not skippable?(@operation) or not is_nil(@tab.pending)}
          variant="secondary"
          class="px-2 py-1 text-[11px]"
        >
          Skip
        </.button>
        <.button
          id="git-operation-abort"
          phx-click="request"
          phx-value-action="abort"
          disabled={not abortable?(@operation) or not is_nil(@tab.pending)}
          variant="danger"
          class="px-2 py-1 text-[11px]"
        >
          Abort
        </.button>
      </div>
    </div>
    """
  end

  ## Action forms

  attr :tab, :map, required: true

  def action_form(assigns) do
    assigns = assign(assigns, :action, assigns.tab.action)

    ~H"""
    <form
      id="git-action-form"
      phx-submit="submit_action"
      class="m-2.5 flex flex-col gap-2 rounded-md border border-accent/40 bg-accent-soft/20 p-2.5"
    >
      <p class="text-[11px] font-semibold uppercase tracking-wide text-accent">
        {action_title(@action)}
      </p>
      <p class="text-[11px] leading-relaxed text-muted">{action_hint(@action)}</p>

      <label :if={@action.kind != :edit_message} class="flex flex-col gap-1">
        <span class="text-[10px] uppercase tracking-wide text-faint">{action_field(@action)}</span>
        <input
          type="text"
          name="value"
          id="git-action-value"
          value={@action.value}
          autocomplete="off"
          phx-mounted={JS.focus()}
          class="w-full rounded border border-line bg-deep px-2 py-1 font-mono text-xs text-ink outline-none transition-colors focus:border-accent/60"
        />
      </label>

      <label :if={@action.kind == :edit_message} class="flex flex-col gap-1">
        <span class="text-[10px] uppercase tracking-wide text-faint">Commit message</span>
        <textarea
          name="value"
          id="git-action-value"
          rows="6"
          phx-mounted={JS.focus()}
          class="w-full rounded border border-line bg-deep px-2 py-1 font-mono text-xs leading-relaxed text-ink outline-none transition-colors focus:border-accent/60"
        >{@action.value}</textarea>
      </label>

      <label
        :if={@action.kind == :create_branch}
        class="flex cursor-pointer items-center gap-2 text-[11px] text-muted"
      >
        <input
          type="checkbox"
          name="checkout"
          value="true"
          checked={@action.checkout?}
          class="size-3.5 cursor-pointer accent-accent"
        /> Check out after creating
      </label>

      <p :if={@action.start} class="font-mono text-[10px] text-faint">
        from {@action.start}
      </p>

      <div class="flex items-center justify-end gap-2">
        <.button
          type="button"
          id="git-action-cancel"
          phx-click="cancel_action"
          variant="ghost"
          class="px-2 py-1 text-[11px]"
        >
          Cancel
        </.button>
        <.button type="submit" id="git-action-submit" variant="primary" class="px-2 py-1 text-[11px]">
          {action_submit(@action)}
        </.button>
      </div>
    </form>
    """
  end

  ## Working tree

  attr :tab, :map, required: true

  def working_tree(assigns) do
    assigns =
      assigns
      |> assign(:staged, Enum.filter(assigns.tab.changes, &FileChange.staged?/1))
      |> assign(:unstaged, Enum.filter(assigns.tab.changes, &FileChange.unstaged?/1))
      |> assign(:selection, MapSet.size(assigns.tab.selected_paths))

    ~H"""
    <div id="git-working-tree" class="flex flex-col gap-3 p-2.5">
      <div
        :if={@tab.changes == []}
        class="rounded-md border border-line-soft p-4 text-center"
        id="git-changes-empty"
      >
        <.icon name="hero-check-circle" class="mx-auto size-5 text-ok" />
        <p class="mt-1 text-xs text-muted">The working tree is clean.</p>
      </div>

      <.file_section
        :if={@staged != []}
        id="git-staged"
        title="Staged"
        files={@staged}
        side={:staged}
        tab={@tab}
      />
      <.file_section
        :if={@unstaged != []}
        id="git-unstaged"
        title="Unstaged"
        files={@unstaged}
        side={:unstaged}
        tab={@tab}
      />

      <div :if={@tab.changes != []} class="flex flex-col gap-2 rounded-md border border-line-soft p-2">
        <div class="flex items-center gap-1.5">
          <span class="text-[10px] uppercase tracking-wide text-faint">
            {@selection} selected
          </span>
          <div class="flex-1"></div>
          <button
            type="button"
            id="git-select-all-paths"
            phx-click="select_all_paths"
            class="cursor-pointer rounded px-1.5 py-0.5 text-[11px] text-muted transition-colors hover:bg-hover hover:text-ink focus-visible:outline-2 focus-visible:outline-accent"
          >
            Select all
          </button>
          <button
            type="button"
            id="git-clear-paths"
            phx-click="clear_paths"
            disabled={@selection == 0}
            class="cursor-pointer rounded px-1.5 py-0.5 text-[11px] text-muted transition-colors hover:bg-hover hover:text-ink disabled:cursor-not-allowed disabled:opacity-40 focus-visible:outline-2 focus-visible:outline-accent"
          >
            Clear
          </button>
        </div>

        <div class="flex items-center gap-1.5">
          <.button
            id="git-stage-selected"
            phx-click="request"
            phx-value-action="stage"
            disabled={@selection == 0 or not is_nil(@tab.pending)}
            variant="secondary"
            class="flex-1 px-2 py-1 text-[11px]"
          >
            <.icon name="hero-plus-circle" class="size-3.5" /> Stage
          </.button>
          <.button
            id="git-unstage-selected"
            phx-click="request"
            phx-value-action="unstage"
            disabled={@selection == 0 or not is_nil(@tab.pending)}
            variant="secondary"
            class="flex-1 px-2 py-1 text-[11px]"
          >
            <.icon name="hero-minus-circle" class="size-3.5" /> Unstage
          </.button>
        </div>

        <form id="git-stash-form" phx-submit="stash_selected" class="flex flex-col gap-1.5">
          <input
            type="text"
            name="message"
            id="git-stash-message"
            value={@tab.stash_message}
            placeholder="Stash message (optional)"
            aria-label="Stash message"
            class="w-full rounded border border-line bg-deep px-2 py-1 text-[11px] text-ink outline-none transition-colors placeholder:text-faint focus:border-accent/60"
          />
          <label class="flex cursor-pointer items-center gap-2 text-[11px] text-muted">
            <input
              type="checkbox"
              name="include_untracked"
              value="true"
              checked={@tab.include_untracked?}
              class="size-3.5 cursor-pointer accent-accent"
            /> Include selected untracked files
          </label>
          <.button
            type="submit"
            id="git-stash-selected"
            disabled={@selection == 0 or not is_nil(@tab.pending)}
            variant="secondary"
            class="px-2 py-1 text-[11px]"
          >
            <.icon name="hero-archive-box-arrow-down" class="size-3.5" /> Stash selected paths
          </.button>
        </form>
      </div>

      <form
        :if={@staged != []}
        id="git-commit-form"
        phx-submit="commit_staged"
        class="flex flex-col gap-1.5 rounded-md border border-line-soft p-2"
      >
        <span class="text-[10px] uppercase tracking-wide text-faint">Commit staged changes</span>
        <textarea
          name="message"
          id="git-commit-message"
          rows="3"
          placeholder="Commit message"
          aria-label="Commit message"
          class="w-full rounded border border-line bg-deep px-2 py-1 font-mono text-[11px] leading-relaxed text-ink outline-none transition-colors placeholder:text-faint focus:border-accent/60"
        >{@tab.commit_message}</textarea>
        <.button
          type="submit"
          id="git-commit-submit"
          disabled={not is_nil(@tab.pending)}
          variant="primary"
          class="px-2 py-1 text-[11px]"
        >
          <.icon name="hero-check" class="size-3.5" /> Commit {length(@staged)} file(s)
        </.button>
      </form>

      <.stash_list tab={@tab} />
    </div>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :files, :list, required: true
  attr :side, :atom, required: true
  attr :tab, :map, required: true

  defp file_section(assigns) do
    ~H"""
    <div>
      <div class="mb-1 flex items-center gap-1.5 px-0.5">
        <span class="text-[10px] font-semibold uppercase tracking-wider text-muted">{@title}</span>
        <span class="font-mono text-[10px] text-faint">{length(@files)}</span>
      </div>
      <div id={@id} role="listbox" aria-multiselectable="true" aria-label={"#{@title} files"}>
        <.file_row :for={file <- @files} file={file} side={@side} tab={@tab} />
      </div>
    </div>
    """
  end

  attr :file, :map, required: true
  attr :side, :atom, required: true
  attr :tab, :map, required: true

  defp file_row(assigns) do
    assigns =
      assigns
      |> assign(:selected, MapSet.member?(assigns.tab.selected_paths, assigns.file.path))
      |> assign(
        :state,
        if(assigns.side == :staged, do: assigns.file.staged, else: assigns.file.unstaged)
      )

    ~H"""
    <button
      type="button"
      id={"git-file-#{@side}-#{slug(@file.path)}"}
      role="option"
      aria-selected={to_string(@selected)}
      phx-click="toggle_path"
      phx-value-path={@file.path}
      class={[
        "flex w-full cursor-pointer items-center gap-2 rounded px-1.5 py-1 text-left transition-colors",
        "focus-visible:outline-2 focus-visible:-outline-offset-2 focus-visible:outline-accent",
        if(@selected, do: "bg-accent-soft/60", else: "hover:bg-hover")
      ]}
    >
      <span class={[
        "flex size-3.5 shrink-0 items-center justify-center rounded-sm border transition-all",
        if(@selected, do: "border-accent bg-accent text-deep", else: "border-line text-transparent")
      ]}>
        <.icon name="hero-check-micro" class="size-2.5" />
      </span>
      <span class={["w-4 shrink-0 text-center font-mono text-[10px] font-bold", state_color(@state)]}>
        {state_code(@state)}
      </span>
      <span class="min-w-0 flex-1 truncate text-[11px] text-ink" title={@file.path}>
        {@file.path}
      </span>
      <span
        :if={@file.original_path}
        class="shrink-0 truncate font-mono text-[10px] text-faint"
        title={"renamed from #{@file.original_path}"}
      >
        ←
      </span>
    </button>
    """
  end

  attr :tab, :map, required: true

  def stash_list(assigns) do
    ~H"""
    <div>
      <div class="mb-1 flex items-center gap-1.5 px-0.5">
        <span class="text-[10px] font-semibold uppercase tracking-wider text-muted">Stashes</span>
        <span class="font-mono text-[10px] text-faint">{length(@tab.stashes)}</span>
      </div>

      <p :if={@tab.stashes == []} id="git-stashes-empty" class="px-0.5 text-[11px] text-faint">
        Nothing stashed yet.
      </p>

      <div :if={@tab.stashes != []} id="git-stashes" class="flex flex-col gap-1">
        <div
          :for={stash <- @tab.stashes}
          id={"git-stash-#{stash.index}"}
          class="rounded-md border border-line-soft p-1.5 transition-colors hover:border-line"
        >
          <p class="truncate text-[11px] text-ink" title={stash.summary}>{stash.summary}</p>
          <p class="flex items-center gap-1.5 font-mono text-[10px] text-faint">
            <span>{stash.reference}</span>
            <span>·</span>
            <span title={absolute_time(stash.created_at)}>{relative_time(stash.created_at)}</span>
          </p>
          <div class="mt-1 flex items-center gap-1">
            <button
              type="button"
              id={"git-stash-apply-#{stash.index}"}
              phx-click="request"
              phx-value-action="apply_stash"
              phx-value-reference={stash.reference}
              disabled={not is_nil(@tab.pending)}
              class={stash_action()}
            >
              Apply
            </button>
            <button
              type="button"
              id={"git-stash-pop-#{stash.index}"}
              phx-click="request"
              phx-value-action="pop_stash"
              phx-value-reference={stash.reference}
              disabled={not is_nil(@tab.pending)}
              class={stash_action()}
            >
              Pop
            </button>
            <button
              type="button"
              id={"git-stash-drop-#{stash.index}"}
              phx-click="request"
              phx-value-action="drop_stash"
              phx-value-reference={stash.reference}
              disabled={not is_nil(@tab.pending)}
              class={[stash_action(), "hover:border-bad/50 hover:text-bad"]}
            >
              Drop
            </button>
          </div>
        </div>
        <p class="px-0.5 text-[10px] leading-relaxed text-faint">
          Applying or popping restores the complete stash, not a selection of its paths.
        </p>
      </div>
    </div>
    """
  end

  ## Notices and dialogs

  attr :id, :string, default: nil
  attr :error, :map, required: true
  attr :class, :any, default: "mt-4"

  def error_notice(assigns) do
    ~H"""
    <div
      id={@id}
      role="alert"
      class={[
        "flex items-start gap-2 rounded-md border p-2.5 text-left",
        if(@error.kind == :conflict,
          do: "border-warn/40 bg-warn-soft/25",
          else: "border-bad/40 bg-bad-soft/25"
        ),
        @class
      ]}
    >
      <.icon
        name={
          if @error.kind == :conflict,
            do: "hero-exclamation-triangle",
            else: "hero-exclamation-circle"
        }
        class={[
          "mt-px size-4 shrink-0",
          if(@error.kind == :conflict, do: "text-warn", else: "text-bad")
        ]}
      />
      <div class="min-w-0 flex-1">
        <p class={[
          "text-[11px] font-semibold",
          if(@error.kind == :conflict, do: "text-warn", else: "text-bad")
        ]}>
          {error_title(@error)}
        </p>
        <pre
          class="mt-0.5 whitespace-pre-wrap break-words font-mono text-[11px] leading-relaxed text-ink/90"
          phx-no-curly-interpolation
        ><%= String.trim(@error.message) %></pre>
      </div>
    </div>
    """
  end

  attr :result, :map, required: true

  def result_notice(assigns) do
    ~H"""
    <div
      id="git-result"
      class="m-2.5 flex items-start gap-2 rounded-md border border-ok/30 bg-ok-soft/20 p-2.5"
    >
      <.icon name="hero-check-circle" class="mt-px size-4 shrink-0 text-ok" />
      <div class="min-w-0 flex-1">
        <p class="text-[11px] font-semibold text-ok">{result_title(@result)}</p>
        <pre
          :if={@result.output != ""}
          class="mt-0.5 max-h-28 overflow-auto whitespace-pre-wrap break-words font-mono text-[11px] leading-relaxed text-muted"
          phx-no-curly-interpolation
        ><%= @result.output %></pre>
      </div>
      <button
        type="button"
        id="git-dismiss-result"
        phx-click="dismiss_result"
        title="Dismiss"
        aria-label="Dismiss"
        class="flex size-5 shrink-0 cursor-pointer items-center justify-center rounded text-faint transition-colors hover:bg-hover hover:text-ink"
      >
        <.icon name="hero-x-mark" class="size-3.5" />
      </button>
    </div>
    """
  end

  attr :confirm, :map, required: true

  def confirm_dialog(assigns) do
    ~H"""
    <div
      id="git-confirm"
      class="fixed inset-0 z-50 flex items-center justify-center p-6"
      role="dialog"
      aria-modal="true"
      aria-labelledby="git-confirm-title"
    >
      <div class="absolute inset-0 bg-black/50" phx-click="cancel_confirm"></div>
      <div class="relative w-full max-w-sm rounded-xl border border-line bg-panel p-4 shadow-2xl shadow-black/30 dark:shadow-black/60">
        <div class="flex items-start gap-2.5">
          <span class="flex size-8 shrink-0 items-center justify-center rounded-lg border border-bad/40 bg-bad-soft/40">
            <.icon name="hero-exclamation-triangle" class="size-4 text-bad" />
          </span>
          <div class="min-w-0">
            <p id="git-confirm-title" class="text-[13px] font-semibold text-ink">
              {@confirm.title}
            </p>
            <p class="mt-1 text-[11px] leading-relaxed text-muted">{@confirm.message}</p>
          </div>
        </div>
        <div class="mt-4 flex items-center justify-end gap-2">
          <.button
            type="button"
            id="git-confirm-cancel"
            phx-click="cancel_confirm"
            variant="secondary"
          >
            Cancel
          </.button>
          <.button
            type="button"
            id="git-confirm-accept"
            phx-click="confirm_action"
            phx-mounted={JS.focus()}
            variant="danger"
          >
            {@confirm.label}
          </.button>
        </div>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :icon, :string, required: true
  attr :title, :string, required: true
  attr :hint, :string, required: true

  def empty(assigns) do
    ~H"""
    <div id={@id} class="flex flex-col items-center gap-1.5 p-8 text-center">
      <.icon name={@icon} class="size-5 text-faint" />
      <p class="text-xs text-muted">{@title}</p>
      <p class="text-[11px] text-faint">{@hint}</p>
    </div>
    """
  end

  ## Presentation helpers

  @doc "A DOM safe, stable identifier for an arbitrary branch name or path."
  def slug(value), do: Base.url_encode64(value, padding: false)

  @doc "The abbreviated form of a commit object id."
  def short_id(id) when is_binary(id), do: String.slice(id, 0, 7)
  def short_id(_id), do: ""

  @doc "The branch or detached head the tab is currently on."
  def head_label(%{snapshot: nil}), do: "loading…"
  def head_label(%{snapshot: %{current_branch: branch}}) when is_binary(branch), do: branch

  def head_label(%{snapshot: %{head: head}}) when is_binary(head),
    do: "detached at #{short_id(head)}"

  def head_label(_tab), do: "no commits"

  defp current_label(%{snapshot: %{current_branch: branch}}) when is_binary(branch), do: branch
  defp current_label(_tab), do: "HEAD"

  # "origin/feature" is called "feature" on the remote itself.
  defp remote_branch_name(%{name: name, remote: remote}) when is_binary(remote),
    do: String.replace_prefix(name, remote <> "/", "")

  defp remote_branch_name(%{name: name}), do: name

  defp ssh_label(%{ssh_mode: :custom}), do: "Custom agent"
  defp ssh_label(_tab), do: "Default agent"

  defp branches(tab, kind) do
    filter = String.downcase(String.trim(tab.filter))

    tab.snapshot.branches
    |> Enum.filter(&(&1.kind == kind))
    |> Enum.filter(&(filter == "" or String.contains?(String.downcase(&1.full_name), filter)))
    |> Enum.sort_by(&{not &1.current?, &1.name})
  end

  defp head?(%{snapshot: %{head: head}}, %{id: id}), do: head == id
  defp head?(_tab, _commit), do: false

  defp menu_open?(%{menu: %{kind: kind, id: id}}, kind, id), do: true
  defp menu_open?(_tab, _kind, _id), do: false

  defp selected_commit(%{selected_commit: nil}), do: nil

  defp selected_commit(tab) do
    Enum.find(tab.snapshot.commits, &(&1.id == tab.selected_commit))
  end

  defp known_commit?(tab, id), do: Enum.any?(tab.snapshot.commits, &(&1.id == id))

  defp different_committer?(commit) do
    commit.committer_email != commit.author_email or
      DateTime.compare(commit.committed_at, commit.authored_at) != :eq
  end

  defp parents_label(%{parents: [_single]}), do: "Parent"
  defp parents_label(_commit), do: "Parents"

  defp lane_center(lane), do: lane * @lane_width + div(@lane_width, 2)

  defp through_path(from, _to),
    do: "M #{lane_center(from)} 0 L #{lane_center(from)} #{@row_height}"

  defp incoming_path(from, to) do
    middle = div(@row_height, 2)

    if from == to do
      "M #{lane_center(from)} 0 L #{lane_center(to)} #{middle}"
    else
      "M #{lane_center(from)} 0 C #{lane_center(from)} #{div(middle, 2)}, " <>
        "#{lane_center(to)} #{div(middle, 2)}, #{lane_center(to)} #{middle}"
    end
  end

  defp outgoing_path(from, to) do
    middle = div(@row_height, 2)

    if from == to do
      "M #{lane_center(from)} #{middle} L #{lane_center(to)} #{@row_height}"
    else
      "M #{lane_center(from)} #{middle} C #{lane_center(from)} #{middle + div(middle, 2)}, " <>
        "#{lane_center(to)} #{middle + div(middle, 2)}, #{lane_center(to)} #{@row_height}"
    end
  end

  @doc "The text color class for a graph lane."
  def lane_color(color) do
    Enum.at(
      ~w(text-accent text-ok text-violet text-warn text-teal text-orange text-bad text-muted),
      rem(color, Layout.colors())
    )
  end

  defp state_code(:added), do: "A"
  defp state_code(:modified), do: "M"
  defp state_code(:deleted), do: "D"
  defp state_code(:renamed), do: "R"
  defp state_code(:copied), do: "C"
  defp state_code(:type_changed), do: "T"
  defp state_code(:untracked), do: "?"
  defp state_code(:conflicted), do: "!"
  defp state_code(_state), do: "·"

  defp state_color(:added), do: "text-ok"
  defp state_color(:modified), do: "text-warn"
  defp state_color(:deleted), do: "text-bad"
  defp state_color(:renamed), do: "text-accent"
  defp state_color(:copied), do: "text-accent"
  defp state_color(:type_changed), do: "text-violet"
  defp state_color(:untracked), do: "text-teal"
  defp state_color(:conflicted), do: "text-bad"
  defp state_color(_state), do: "text-faint"

  defp signature_label(:good), do: "Good signature"
  defp signature_label(:bad), do: "Bad signature"
  defp signature_label(:good_unknown_validity), do: "Good signature, unknown validity"
  defp signature_label(:good_expired), do: "Good signature, expired"
  defp signature_label(:good_expired_key), do: "Good signature, expired key"
  defp signature_label(:good_revoked_key), do: "Good signature, revoked key"
  defp signature_label(:cannot_check), do: "Signature could not be checked"
  defp signature_label(:no_signature), do: "Not signed"
  defp signature_label(_status), do: "Unknown signature state"

  defp signature_icon(%{signature_status: :no_signature}), do: "hero-lock-open"
  defp signature_icon(%{signature_status: :good}), do: "hero-shield-check"
  defp signature_icon(%{signature_status: :bad}), do: "hero-shield-exclamation"
  defp signature_icon(_commit), do: "hero-shield-exclamation"

  defp signature_color(%{signature_status: :good}), do: "text-ok"
  defp signature_color(%{signature_status: :bad}), do: "text-bad"
  defp signature_color(%{signature_status: :no_signature}), do: "text-faint"
  defp signature_color(_commit), do: "text-warn"

  @doc "The human name of an in-progress operation."
  def operation_name(%Operation{kind: :cherry_pick}), do: "Cherry-pick"
  def operation_name(%Operation{kind: kind}), do: kind |> to_string() |> String.capitalize()

  defp operation_hint(%Operation{kind: :bisect}),
    do: "This backend cannot drive a bisect. Finish it from a terminal."

  defp operation_hint(%Operation{kind: kind}) do
    "Resolve the conflicting files, stage them, then continue the #{kind_name(kind)}."
  end

  defp kind_name(:cherry_pick), do: "cherry-pick"
  defp kind_name(kind), do: to_string(kind)

  defp continuable?(%Operation{kind: kind}), do: kind in [:merge, :rebase, :cherry_pick, :revert]
  defp skippable?(%Operation{kind: kind}), do: kind in [:rebase, :cherry_pick, :revert]
  defp abortable?(%Operation{kind: kind}), do: kind in [:merge, :rebase, :cherry_pick, :revert]

  defp error_title(%{kind: :conflict}), do: "Stopped for conflict resolution"
  defp error_title(%{kind: :invalid_repository}), do: "Not a Git worktree"
  defp error_title(%{kind: :git_not_found}), do: "Git is unavailable"
  defp error_title(%{kind: :invalid_argument}), do: "That will not work"
  defp error_title(%{kind: :unsupported}), do: "Not supported here"
  defp error_title(%{kind: :invalid_output}), do: "Unexpected Git output"
  defp error_title(_error), do: "Git reported a problem"

  defp result_title(%{action: action}) do
    action |> to_string() |> String.replace("_", " ") |> String.capitalize()
  end

  defp action_title(%{kind: :create_branch}), do: "Create branch"
  defp action_title(%{kind: :rename_branch}), do: "Rename branch"
  defp action_title(%{kind: :checkout_remote}), do: "Check out remote branch"
  defp action_title(%{kind: :edit_message}), do: "Edit commit message"

  defp action_field(%{kind: :rename_branch}), do: "New name"
  defp action_field(%{kind: :checkout_remote}), do: "Local branch name"
  defp action_field(_action), do: "Branch name"

  defp action_submit(%{kind: :create_branch}), do: "Create"
  defp action_submit(%{kind: :rename_branch}), do: "Rename"
  defp action_submit(%{kind: :checkout_remote}), do: "Check out"
  defp action_submit(%{kind: :edit_message}), do: "Save message"

  defp action_hint(%{kind: :create_branch}),
    do: "The new branch starts at the commit shown below."

  defp action_hint(%{kind: :rename_branch}),
    do: "Only the local branch is renamed; its upstream is left alone."

  defp action_hint(%{kind: :checkout_remote}),
    do: "A local branch is created tracking the remote one, then checked out."

  defp action_hint(%{kind: :edit_message}),
    do:
      "Editing an older message rewrites this commit and every descendant, " <>
        "so their object ids change. The worktree must be clean."

  defp toolbar_button do
    [
      "flex cursor-pointer items-center gap-1 rounded px-1.5 py-1 text-[11px] text-muted",
      "transition-colors hover:bg-hover hover:text-ink disabled:cursor-not-allowed disabled:opacity-40",
      "focus-visible:outline-2 focus-visible:outline-accent"
    ]
  end

  defp stash_action do
    [
      "cursor-pointer rounded border border-line-soft px-1.5 py-0.5 text-[10px] text-muted",
      "transition-colors hover:bg-hover hover:text-ink disabled:cursor-not-allowed disabled:opacity-40",
      "focus-visible:outline-2 focus-visible:outline-accent"
    ]
  end

  @doc "A compact relative time, like the graph column shows."
  def relative_time(%DateTime{} = at) do
    case DateTime.diff(DateTime.utc_now(), at) do
      seconds when seconds < 60 -> "just now"
      seconds when seconds < 3_600 -> "#{div(seconds, 60)}m ago"
      seconds when seconds < 86_400 -> "#{div(seconds, 3_600)}h ago"
      seconds when seconds < 2_592_000 -> "#{div(seconds, 86_400)}d ago"
      seconds when seconds < 31_536_000 -> "#{div(seconds, 2_592_000)}mo ago"
      seconds -> "#{div(seconds, 31_536_000)}y ago"
    end
  end

  @doc "The full timestamp, in the machine's local time."
  def absolute_time(%DateTime{} = at) do
    at
    |> DateTime.to_naive()
    |> NaiveDateTime.to_erl()
    |> :calendar.universal_time_to_local_time()
    |> NaiveDateTime.from_erl!()
    |> Calendar.strftime("%Y-%m-%d %H:%M")
  end
end
