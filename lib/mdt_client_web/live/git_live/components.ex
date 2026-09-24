defmodule MDTClientWeb.GitLive.Components do
  @moduledoc """
  The panels, menus and dialogs of the Git workspace.

  Everything here is a pure function of the tab it is given, so the LiveView
  stays a coordinator: it owns repository handles, snapshots and commands, and
  this module owns how they look.
  """
  use MDTClientWeb, :html

  alias MDTClient.Git.FileChange
  alias MDTClient.Git.FileDiff
  alias MDTClient.Git.Operation
  alias MDTClient.Git.Tag
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
      <.tab_strip
        id="git-tabs"
        role="tablist"
        class="flex min-w-0 flex-1 items-stretch overflow-x-auto"
      >
        <div
          :for={tab <- @tabs}
          draggable="true"
          data-sortable-id={tab.id}
          class={[
            "group flex shrink-0 items-center border-r border-line-soft transition-colors",
            if(tab.id == @active_id, do: "bg-deep", else: "hover:bg-hover"),
            tab_drag_classes()
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
      </.tab_strip>

      <button
        type="button"
        id="git-open-folder"
        phx-click="open_repository_dialog"
        title="Open or clone a repository"
        aria-label="Open or clone a repository"
        class="flex w-9 shrink-0 cursor-pointer items-center justify-center border-l border-line-soft text-muted transition-colors hover:bg-hover hover:text-ink focus-visible:outline-2 focus-visible:-outline-offset-2 focus-visible:outline-accent"
      >
        <.icon :if={is_nil(@opening)} name="hero-plus" class="size-4" />
        <.icon
          :if={@opening}
          name="hero-arrow-path"
          class="size-4 text-accent motion-safe:animate-spin"
        />
      </button>

      <.ssh_keys :if={@tab} tab={@tab} />
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
            title: this.el.dataset.title || "Open a Git repository",
          }

          try {
            const selection = dialog
              ? await dialog.open(options)
              : await invoke("plugin:dialog|open", {options})
            const first = Array.isArray(selection) ? selection[0] : selection
            const path = first && typeof first === "object" ? first.path : first

            if (path) this.pushEvent(this.el.dataset.event || "open_repository", {path})
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

  ## SSH credentials

  attr :tab, :map, required: true

  def ssh_keys(assigns) do
    ~H"""
    <div class="relative flex shrink-0 items-center border-l border-line-soft px-1.5">
      <button
        type="button"
        id="git-ssh-keys"
        phx-click="toggle_ssh"
        aria-haspopup="dialog"
        aria-expanded={to_string(@tab.ssh_open?)}
        title="Configure SSH keys"
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
          class={[
            "size-3.5",
            if(@tab.repository.ssh_key, do: "text-accent", else: "text-faint")
          ]}
        />
        <span class="hidden sm:inline">{ssh_label(@tab)}</span>
      </button>

      <div
        :if={@tab.ssh_open?}
        id="git-ssh-popover"
        role="dialog"
        aria-label="SSH authentication"
        class="absolute right-0 top-9 z-40 w-96 rounded-lg border border-line bg-panel p-3 shadow-xl shadow-black/20 dark:shadow-black/50"
      >
        <p class="text-[11px] font-semibold uppercase tracking-wide text-muted">SSH keys</p>
        <p class="mt-1 text-[11px] leading-relaxed text-faint">
          Choose the key pair MDT will use for SSH remotes. The paths are saved for all
          repository tabs; the private key stays on this machine.
        </p>

        <form id="git-ssh-form" phx-submit="save_ssh" class="mt-3 flex flex-col gap-2">
          <label class="block text-[11px] text-muted" for="git-ssh-private-key">
            SSH private key
          </label>
          <div class="flex gap-1.5">
            <input
              type="text"
              name="private_key"
              id="git-ssh-private-key"
              value={@tab.ssh_private_key}
              placeholder="~/.ssh/id_ed25519"
              autocomplete="off"
              class="min-w-0 flex-1 rounded border border-line bg-deep px-2 py-1 font-mono text-[11px] text-ink outline-none transition-colors placeholder:text-faint focus:border-accent/60"
            />
            <.button
              type="button"
              id="git-browse-private-key"
              phx-hook=".OpenSSHKey"
              data-kind="private"
              class="px-2 py-1 text-[11px]"
            >
              Browse
            </.button>
          </div>

          <label class="mt-1 block text-[11px] text-muted" for="git-ssh-public-key">
            SSH public key
          </label>
          <div class="flex gap-1.5">
            <input
              type="text"
              name="public_key"
              id="git-ssh-public-key"
              value={@tab.ssh_public_key}
              placeholder="~/.ssh/id_ed25519.pub"
              autocomplete="off"
              class="min-w-0 flex-1 rounded border border-line bg-deep px-2 py-1 font-mono text-[11px] text-ink outline-none transition-colors placeholder:text-faint focus:border-accent/60"
            />
            <.button
              type="button"
              id="git-browse-public-key"
              phx-hook=".OpenSSHKey"
              data-kind="public"
              class="px-2 py-1 text-[11px]"
            >
              Browse
            </.button>
            <.button
              type="button"
              id="git-copy-public-key"
              phx-click="copy_public_key"
              phx-hook=".CopySSHKey"
              disabled={@tab.ssh_public_key == ""}
              title="Copy public key"
              aria-label="Copy public key"
              class="px-2 py-1"
            >
              <.icon name="hero-clipboard-document" class="size-3.5" />
            </.button>
          </div>

          <p class="text-[10px] leading-relaxed text-faint">
            Passphrase-protected private keys are not supported yet. MDT never copies or
            stores key contents.
          </p>

          <p :if={@tab.ssh_error} id="git-ssh-error" class="text-[11px] text-bad">
            {@tab.ssh_error}
          </p>

          <div class="flex items-center justify-between gap-2">
            <.button
              :if={@tab.repository.ssh_key}
              type="button"
              id="git-clear-ssh"
              phx-click="clear_ssh"
              variant="ghost"
              class="px-2 py-1 text-[11px]"
            >
              Clear
            </.button>
            <span :if={!@tab.repository.ssh_key}></span>
            <div class="flex items-center gap-2">
              <.button type="button" phx-click="toggle_ssh" variant="ghost" class="px-2 py-1">
                Cancel
              </.button>
              <.button type="submit" variant="primary" class="px-2 py-1">Save keys</.button>
            </div>
          </div>
        </form>

        <div :if={@tab.remotes != []} class="mt-3 border-t border-line-soft pt-3">
          <p class="text-[11px] font-semibold uppercase tracking-wide text-muted">Remotes</p>
          <div class="mt-1.5 flex max-h-44 flex-col gap-1.5 overflow-y-auto">
            <div
              :for={remote <- @tab.remotes}
              id={"git-ssh-remote-#{slug(remote.name)}"}
              class="rounded-md border border-line-soft bg-deep p-2"
            >
              <div class="flex items-center gap-2">
                <span class="min-w-0 flex-1 truncate text-xs font-medium text-ink">
                  {remote.name}
                </span>
                <span
                  id={"git-ssh-remote-kind-#{slug(remote.name)}"}
                  class="rounded bg-active px-1.5 py-0.5 text-[9px] uppercase text-muted"
                >
                  {remote.kind}
                </span>
              </div>
              <p class="mt-1 truncate font-mono text-[10px] text-faint" title={remote.push_url}>
                {remote.push_url}
              </p>
              <div
                :if={remote.ssh_url}
                class="mt-2 rounded border border-warn/30 bg-warn-soft px-2 py-1.5"
              >
                <p class="text-[10px] leading-relaxed text-warn">
                  SSH keys cannot authenticate this HTTP remote.
                </p>
                <button
                  type="button"
                  id={"git-use-ssh-#{slug(remote.name)}"}
                  phx-click="use_ssh_remote"
                  phx-value-remote={remote.name}
                  disabled={not is_nil(@tab.pending)}
                  class="mt-1 cursor-pointer text-[10px] font-medium text-warn underline underline-offset-2 disabled:cursor-not-allowed disabled:opacity-50"
                >
                  Change to {remote.ssh_url}
                </button>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".OpenSSHKey">
      export default {
        mounted() {
          this.el.addEventListener("click", async (event) => {
            event.preventDefault()
            await this.pick()
          })
        },

        async pick() {
          const dialog = window.__TAURI__?.dialog
          const invoke = window.__TAURI_INTERNALS__?.invoke || window.__TAURI__?.core?.invoke

          if (!dialog && !invoke) {
            return this.pushEvent("ssh_picker_unavailable", {
              reason: "The native key picker is only available in the desktop app. Enter the path instead.",
            })
          }

          const options = {
            directory: false,
            multiple: false,
            title: this.el.dataset.kind === "private" ? "Choose an SSH private key" : "Choose an SSH public key",
          }

          try {
            const selection = dialog
              ? await dialog.open(options)
              : await invoke("plugin:dialog|open", {options})
            const first = Array.isArray(selection) ? selection[0] : selection
            const path = first && typeof first === "object" ? first.path : first

            if (path) this.pushEvent("select_ssh_key", {kind: this.el.dataset.kind, path})
          } catch (error) {
            this.pushEvent("ssh_picker_unavailable", {
              reason: `The key picker could not be opened: ${error?.message || error}`,
            })
          }
        }
      }
    </script>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".CopySSHKey">
      export default {
        mounted() {
          this.handleEvent("git_copy_public_key", ({contents}) => {
            navigator.clipboard?.writeText(contents || "")
          })
        }
      }
    </script>
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
          Open a folder on this machine, or clone one from a remote. Either way it
          gets its own tab, and the tabs come back the next time you are here.
        </p>

        <div class="mt-5 flex items-center justify-center gap-2">
          <.button id="git-empty-open" phx-click="open_repository_dialog" variant="primary">
            <.icon name="hero-folder-open" class="size-4" /> Open folder
          </.button>
          <.button
            id="git-empty-clone"
            phx-click="set_open_mode"
            phx-value-mode="clone"
            variant="secondary"
          >
            <.icon name="hero-cloud-arrow-down" class="size-4" /> Clone
          </.button>
        </div>

        <.error_notice :if={@error} id="git-open-error" error={@error} />
      </div>
    </div>
    """
  end

  @doc """
  The chooser for bringing a repository into the app.

  It offers both ways of starting: picking a folder already on this machine, or
  cloning one from a remote into a new folder. The typed path is kept alongside
  the native picker so the tool still works where the picker cannot run, such as
  a browser, and so a path can simply be pasted.
  """
  attr :dialog, :map, required: true

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
              Add a repository
            </p>
            <p
              :if={@dialog.reason}
              id="git-open-dialog-reason"
              class="mt-1 text-[11px] leading-relaxed text-muted"
            >
              {@dialog.reason}
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

        <div class="mt-3 flex items-center gap-0.5 rounded-md border border-line-soft p-0.5">
          <.open_mode_tab dialog={@dialog} mode="open" label="Open a folder" icon="hero-folder" />
          <.open_mode_tab
            dialog={@dialog}
            mode="clone"
            label="Clone a remote"
            icon="hero-cloud-arrow-down"
          />
        </div>

        <%= if @dialog.mode == "clone" do %>
          <form id="git-clone-form" phx-submit="clone_repository" class="mt-3 flex flex-col gap-2">
            <label class="flex flex-col gap-1">
              <span class="text-[10px] uppercase tracking-wide text-faint">Repository URL</span>
              <input
                type="text"
                name="url"
                id="git-clone-url"
                value={@dialog.url}
                placeholder="git@github.com:owner/project.git"
                autocomplete="off"
                phx-mounted={JS.focus()}
                class={dialog_input()}
              />
            </label>

            <label class="flex flex-col gap-1">
              <span class="text-[10px] uppercase tracking-wide text-faint">Clone into</span>
              <span class="flex items-center gap-2">
                <input
                  type="text"
                  name="parent"
                  id="git-clone-parent"
                  value={@dialog.parent}
                  placeholder="/home/you/projects"
                  autocomplete="off"
                  class={dialog_input()}
                />
                <.button
                  type="button"
                  id="git-clone-browse"
                  phx-hook=".OpenFolder"
                  data-event="clone_parent_selected"
                  data-title="Choose where to clone"
                  variant="secondary"
                  class="shrink-0 px-2 py-1.5"
                >
                  Browse
                </.button>
              </span>
            </label>

            <label class="flex flex-col gap-1">
              <span class="text-[10px] uppercase tracking-wide text-faint">Folder name</span>
              <input
                type="text"
                name="name"
                id="git-clone-name"
                value={@dialog.name}
                placeholder="taken from the URL"
                autocomplete="off"
                class={dialog_input()}
              />
            </label>

            <.error_notice :if={@dialog.error} id="git-open-dialog-error" error={@dialog.error} />

            <div class="flex items-center justify-between gap-2">
              <p class="min-w-0 truncate text-[11px] text-faint">
                <%= if @dialog.cloning do %>
                  Cloning into {@dialog.cloning}…
                <% else %>
                  A new folder is created; it must not exist yet.
                <% end %>
              </p>
              <.button
                type="submit"
                id="git-clone-submit"
                disabled={not is_nil(@dialog.cloning)}
                variant="primary"
              >
                <.icon
                  :if={@dialog.cloning}
                  name="hero-arrow-path"
                  class="size-4 motion-safe:animate-spin"
                /> Clone
              </.button>
            </div>
          </form>
        <% else %>
          <div class="mt-3 flex flex-col gap-2">
            <.button
              id="git-choose-folder"
              phx-hook=".OpenFolder"
              variant="secondary"
              class="w-full py-2"
            >
              <.icon name="hero-folder-open" class="size-4" /> Choose a folder…
            </.button>

            <form id="git-manual-open" phx-submit="open_repository" class="flex items-center gap-2">
              <input
                type="text"
                name="path"
                id="git-open-path"
                value={@dialog.path}
                placeholder="or type a path"
                aria-label="Repository path"
                autocomplete="off"
                class={dialog_input()}
              />
              <.button type="submit" variant="primary">Open</.button>
            </form>

            <.error_notice :if={@dialog.error} id="git-open-dialog-error" error={@dialog.error} />

            <p class="text-[11px] text-faint">Any folder inside the worktree works.</p>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  attr :dialog, :map, required: true
  attr :mode, :string, required: true
  attr :label, :string, required: true
  attr :icon, :string, required: true

  defp open_mode_tab(assigns) do
    ~H"""
    <button
      type="button"
      id={"git-open-mode-#{@mode}"}
      phx-click="set_open_mode"
      phx-value-mode={@mode}
      aria-pressed={to_string(@dialog.mode == @mode)}
      class={[
        "flex flex-1 cursor-pointer items-center justify-center gap-1.5 rounded px-2 py-1 text-[11px] transition-colors",
        "focus-visible:outline-2 focus-visible:-outline-offset-2 focus-visible:outline-accent",
        if(@dialog.mode == @mode,
          do: "bg-active text-ink",
          else: "text-muted hover:bg-hover hover:text-ink"
        )
      ]}
    >
      <.icon name={@icon} class="size-3.5" />
      {@label}
    </button>
    """
  end

  defp dialog_input do
    [
      "w-full rounded-md border border-line bg-deep px-2.5 py-1.5 font-mono text-xs text-ink",
      "outline-none transition-colors placeholder:text-faint focus:border-accent/60"
    ]
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
      phx-hook="MDTClientWeb.PanelComponents.RowMenu"
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

      <.stash_list tab={@tab} />
    </aside>
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
            name={branch_icon(@branch)}
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

  attr :snapshot, :map, required: true
  attr :graph, :map, required: true
  attr :changes, :list, required: true
  attr :pending, :any, default: nil
  attr :pending_label, :string, default: nil
  attr :limit, :integer, required: true
  attr :panel, :string, required: true
  attr :selected_commit, :string, default: nil
  attr :selected_commits, :any, default: MapSet.new()
  attr :selected_branch, :string, default: nil
  attr :menu, :map, default: nil
  attr :diff, :map, default: nil
  attr :limits, :list, required: true

  def graph_panel(assigns) do
    assigns =
      assigns
      |> assign(:rows, assigns.graph.rows)
      |> assign(:lanes, min(assigns.graph.lane_count, visible_lanes()))

    ~H"""
    <section id="git-graph" class="@container flex min-w-0 flex-1 flex-col bg-app">
      <div class="flex h-9 shrink-0 items-center gap-2 border-b border-line-soft bg-panel px-2.5">
        <span class="flex min-w-0 items-center gap-1.5">
          <.icon
            name={if @snapshot.detached?, do: "hero-scissors", else: "hero-arrows-right-left"}
            class={[
              "size-3.5 shrink-0",
              if(@snapshot.detached?, do: "text-warn", else: "text-ok")
            ]}
          />
          <span class="min-w-0 truncate font-mono text-xs text-ink">
            {head_label(%{snapshot: @snapshot})}
          </span>
        </span>

        <span
          :if={@snapshot.operation}
          class="shrink-0 rounded border border-warn/40 bg-warn-soft/40 px-1.5 py-0.5 text-[10px] font-semibold text-warn"
        >
          {operation_name(@snapshot.operation)} in progress
        </span>

        <div class="flex-1"></div>

        <span
          :if={@pending}
          id="git-operation-status"
          class="flex shrink-0 items-center gap-1.5 text-[11px] text-accent"
        >
          <.icon name="hero-arrow-path" class="size-3.5 motion-safe:animate-spin" />
          {@pending_label}
        </span>

        <div class="flex shrink-0 items-center gap-0.5">
          <button
            type="button"
            id="git-fetch"
            phx-click="request"
            phx-value-action="fetch"
            disabled={not is_nil(@pending)}
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
            disabled={not is_nil(@pending) or @snapshot.detached?}
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
            disabled={not is_nil(@pending) or @snapshot.detached?}
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
            <option :for={limit <- @limits} value={limit} selected={limit == @limit}>
              {limit}
            </option>
          </select>
        </form>

        <button
          type="button"
          id="git-refresh"
          phx-click="request"
          phx-value-action="refresh"
          disabled={not is_nil(@pending)}
          title="Refresh"
          aria-label="Refresh"
          class="flex size-6 shrink-0 cursor-pointer items-center justify-center rounded text-faint transition-colors hover:bg-hover hover:text-ink disabled:cursor-not-allowed disabled:opacity-40 focus-visible:outline-2 focus-visible:outline-accent"
        >
          <.icon name="hero-arrow-path" class="size-3.5" />
        </button>
      </div>

      <.diff_view :if={@diff} open={@diff} />

      <div
        :if={is_nil(@diff) and @rows != []}
        id="git-commit-columns"
        aria-hidden="true"
        class="flex h-6 shrink-0 items-center border-b border-line-soft bg-panel/60 pl-2 pr-1 text-[10px] uppercase tracking-wider text-faint"
      >
        <span class="hidden shrink-0 truncate text-right @[44rem]:block" style={ref_column_style()}>
          Branch
        </span>
        <span class="flex min-w-0 flex-1 items-center gap-2">
          <span class="shrink-0" style={graph_column_style(@lanes)}>Graph</span>
          <span class="min-w-0 flex-1 truncate">Commit</span>
          <span class="w-20 shrink-0 truncate text-right">Author</span>
          <span class="w-16 shrink-0 truncate text-right">When</span>
          <span class="w-14 shrink-0 truncate text-right">SHA</span>
        </span>
        <span class="mr-1 w-5 shrink-0"></span>
      </div>

      <div
        :if={is_nil(@diff)}
        id="git-commits"
        phx-hook="MDTClientWeb.PanelComponents.RowMenu"
        role="listbox"
        aria-label="Commits"
        class="min-h-0 flex-1 overflow-y-auto"
      >
        <.pending_row
          :if={@changes != []}
          graph={@graph}
          changes={@changes}
          panel={@panel}
          lanes={@lanes}
        />

        <p
          :if={@rows == [] and @changes == []}
          id="git-commits-empty"
          class="px-3 py-8 text-center text-xs text-faint"
        >
          This repository has no commits yet.
        </p>
        <.commit_row
          :for={row <- @rows}
          row={row}
          lanes={@lanes}
          head={@snapshot.head}
          selected={MapSet.member?(@selected_commits, row.commit.id)}
          selected_branch={@selected_branch}
          menu={@menu}
        />
      </div>
    </section>
    """
  end

  attr :graph, :map, required: true
  attr :changes, :list, required: true
  attr :panel, :string, required: true
  attr :lanes, :integer, required: true

  defp pending_row(assigns) do
    assigns =
      assigns
      |> assign(:row, Layout.pending_row(assigns.graph))
      |> assign(:unstaged, Enum.count(assigns.changes, &FileChange.unstaged?/1))
      |> assign(:staged, Enum.count(assigns.changes, &FileChange.staged?/1))

    ~H"""
    <div
      id="git-wip-row"
      class={[
        "group relative flex items-center border-b border-line-soft/40 pl-2 transition-colors",
        if(@panel == "changes",
          do: "bg-accent-soft/50 shadow-[inset_2px_0_0_0_var(--color-accent)]",
          else: "hover:bg-hover/70"
        )
      ]}
      style={"height: #{row_height()}px"}
    >
      <span class="hidden h-full shrink-0 @[44rem]:block" style={ref_column_style()}></span>

      <button
        type="button"
        id="git-select-wip"
        phx-click="show_working_tree"
        aria-pressed={to_string(@panel == "changes")}
        title="Uncommitted changes in the working tree"
        class="flex h-full min-w-0 flex-1 cursor-pointer items-center gap-2 pr-1 text-left focus-visible:outline-2 focus-visible:-outline-offset-2 focus-visible:outline-accent"
      >
        <.graph_cell row={@row} lanes={@lanes} pending />

        <span class="flex min-w-0 flex-1 items-center gap-1.5">
          <span class="shrink-0 rounded border border-dashed border-line px-1 py-px font-mono text-[10px] leading-4 text-muted">
            // WIP
          </span>
          <span class="min-w-0 truncate text-[13px] text-muted">Uncommitted changes</span>
        </span>

        <span class="flex shrink-0 items-center gap-1.5 pr-1 font-mono text-[11px]">
          <span :if={@unstaged > 0} class="text-warn" title={"#{@unstaged} unstaged"}>
            ~{@unstaged}
          </span>
          <span :if={@staged > 0} class="text-ok" title={"#{@staged} staged"}>+{@staged}</span>
        </span>
      </button>
      <span class="mr-1 size-5 shrink-0"></span>
    </div>
    """
  end

  attr :open, :map, required: true

  defp diff_view(assigns) do
    ~H"""
    <div id="git-diff" class="flex min-h-0 flex-1 flex-col">
      <div class="flex h-8 shrink-0 items-center gap-2 border-b border-line-soft bg-panel/60 px-2.5">
        <.icon name="hero-document-magnifying-glass" class="size-3.5 shrink-0 text-accent" />
        <span class="min-w-0 truncate font-mono text-xs text-ink" title={@open.path}>
          {@open.path}
        </span>

        <%!-- A commit diff has one side by definition; a working tree file has two. --%>
        <span
          :if={@open.side == :commit}
          class="shrink-0 rounded border border-line bg-deep px-1.5 py-0.5 font-mono text-[10px] text-muted"
        >
          in {short_id(@open.commit)}
        </span>
        <div :if={@open.side != :commit} class="flex shrink-0 items-center gap-0.5">
          <.diff_side_tab open={@open} side={:unstaged} label="Unstaged" />
          <.diff_side_tab open={@open} side={:staged} label="Staged" />
        </div>

        <span :if={@open.diff} class="shrink-0 font-mono text-[10px] text-ok">
          +{FileDiff.counts(@open.diff).added}
        </span>
        <span :if={@open.diff} class="shrink-0 font-mono text-[10px] text-bad">
          −{FileDiff.counts(@open.diff).removed}
        </span>

        <div class="flex-1"></div>

        <button
          type="button"
          id="git-close-diff"
          phx-click="close_diff"
          title="Back to the graph"
          aria-label="Back to the graph"
          class="flex size-6 shrink-0 cursor-pointer items-center justify-center rounded text-faint transition-colors hover:bg-hover hover:text-ink focus-visible:outline-2 focus-visible:outline-accent"
        >
          <.icon name="hero-x-mark" class="size-4" />
        </button>
      </div>

      <div class="min-h-0 flex-1 overflow-auto bg-deep">
        <%= cond do %>
          <% @open.error -> %>
            <.error_notice id="git-diff-error" error={@open.error} class="m-2.5" />
          <% is_nil(@open.diff) -> %>
            <p
              id="git-diff-loading"
              class="flex items-center justify-center gap-2 p-8 text-xs text-muted"
            >
              <.icon name="hero-arrow-path" class="size-4 text-accent motion-safe:animate-spin" />
              Reading the diff…
            </p>
          <% @open.diff.binary? -> %>
            <p id="git-diff-binary" class="p-8 text-center text-xs text-muted">
              Git treats this file as binary, so there is nothing to show line by line.
            </p>
          <% @open.diff.hunks == [] -> %>
            <p id="git-diff-empty" class="p-8 text-center text-xs text-muted">
              <%= if @open.side == :commit do %>
                This commit left the file untouched.
              <% else %>
                Nothing changed on this side of the index.
              <% end %>
            </p>
          <% true -> %>
            <div id="git-diff-body" class="min-w-max py-1 font-mono text-xs leading-5">
              <div :for={hunk <- @open.diff.hunks}>
                <div class="flex bg-accent-soft/30 px-2 py-0.5 text-[11px] text-accent">
                  <span class="whitespace-pre">{hunk.header}</span>
                </div>
                <div
                  :for={line <- hunk.lines}
                  class={["flex", diff_line_class(line.kind)]}
                  style="content-visibility: auto; contain-intrinsic-size: 0 20px;"
                >
                  <span class="w-12 shrink-0 select-none pr-2 text-right text-ink/35">
                    {line.old_line}
                  </span>
                  <span class="w-12 shrink-0 select-none pr-2 text-right text-ink/35">
                    {line.new_line}
                  </span>
                  <span class="w-4 shrink-0 select-none text-center">{diff_sign(line.kind)}</span>
                  <code class="whitespace-pre pr-4">{line.text}</code>
                </div>
              </div>
              <p
                :if={@open.diff.truncated?}
                id="git-diff-truncated"
                class="px-2 py-2 text-[11px] text-warn"
              >
                This diff is longer than the view shows; the rest was left out.
              </p>
            </div>
        <% end %>
      </div>
    </div>
    """
  end

  attr :open, :map, required: true
  attr :side, :atom, required: true
  attr :label, :string, required: true

  defp diff_side_tab(assigns) do
    ~H"""
    <button
      type="button"
      id={"git-diff-side-#{@side}"}
      phx-click="view_diff"
      phx-value-path={@open.path}
      phx-value-side={@side}
      aria-pressed={to_string(@open.side == @side)}
      class={[
        "cursor-pointer rounded px-1.5 py-0.5 text-[10px] transition-colors",
        "focus-visible:outline-2 focus-visible:outline-accent",
        if(@open.side == @side,
          do: "bg-active text-ink",
          else: "text-muted hover:bg-hover hover:text-ink"
        )
      ]}
    >
      {@label}
    </button>
    """
  end

  defp diff_line_class(:added), do: "bg-ok-soft/30 text-ink"
  defp diff_line_class(:removed), do: "bg-bad-soft/30 text-ink"
  defp diff_line_class(_kind), do: "text-ink/80"

  defp diff_sign(:added), do: "+"
  defp diff_sign(:removed), do: "−"
  defp diff_sign(_kind), do: ""

  attr :row, :map, required: true
  attr :lanes, :integer, required: true
  attr :head, :string, default: nil
  attr :selected, :boolean, default: false
  attr :selected_branch, :string, default: nil
  attr :menu, :map, default: nil

  defp commit_row(assigns) do
    assigns =
      assigns
      |> assign(:id, assigns.row.commit.id)
      |> assign(:refs, ref_labels(assigns.row.commit.labels))

    ~H"""
    <%!-- Skipping off-screen rows keeps a long graph cheap, but it also clips
          everything in a row to the row's box, so that is lifted while the
          row's ref list hangs open over the rows below. --%>
    <div
      id={"git-commit-#{@id}"}
      data-menu-kind="commit"
      data-menu-id={@id}
      class={[
        "group relative flex select-none items-center border-b border-line-soft/40 pl-2 transition-colors",
        "[content-visibility:auto] has-[[data-ref-list][data-open]]:[content-visibility:visible]",
        if(@selected,
          do: "bg-accent-soft/50 shadow-[inset_2px_0_0_0_var(--color-accent)]",
          else: "hover:bg-hover/70"
        )
      ]}
      style={"height: #{row_height()}px; contain-intrinsic-size: 0 #{row_height()}px;"}
    >
      <%!-- The ref column sits outside the row button so a chip can be picked
            without that click also meaning "select this commit". It keeps its
            width either way, so every node in the graph lines up. --%>
      <.ref_column
        :if={@refs != []}
        commit={@row.commit}
        refs={@refs}
        selected_branch={@selected_branch}
        menu={@menu}
      />
      <div
        :if={@refs == []}
        phx-click="select_commit"
        phx-value-id={@id}
        aria-hidden="true"
        class="hidden h-full shrink-0 cursor-pointer @[44rem]:block"
        style={ref_column_style()}
      >
      </div>

      <button
        type="button"
        id={"git-select-commit-#{@id}"}
        role="option"
        aria-selected={to_string(@selected)}
        phx-click="select_commit"
        phx-value-id={@id}
        class="flex h-full min-w-0 flex-1 cursor-pointer items-center gap-2 pr-1 text-left focus-visible:outline-2 focus-visible:-outline-offset-2 focus-visible:outline-accent"
      >
        <.graph_cell row={@row} lanes={@lanes} head={@head} />

        <span class="flex min-w-0 flex-1 items-center gap-1.5">
          <span
            :if={@refs != []}
            class="flex min-w-0 max-w-40 shrink-0 items-center gap-1 @[44rem]:hidden"
          >
            <.label_chip label={hd(@refs)} />
            <span
              :if={length(@refs) > 1}
              class="shrink-0 rounded border border-line bg-deep px-1 py-px font-mono text-[10px] leading-4 text-faint"
            >
              +{length(@refs) - 1}
            </span>
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
        aria-expanded={to_string(menu_open?(@menu, :commit, @id))}
        title="Commit actions"
        aria-label={"Actions for commit #{short_id(@id)}"}
        class={[
          "mr-1 flex size-5 shrink-0 cursor-pointer items-center justify-center rounded transition-all",
          "hover:bg-panel hover:text-ink focus:opacity-100 focus-visible:outline-2 focus-visible:outline-accent",
          "group-hover:opacity-100",
          if(@selected,
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
  attr :pending, :boolean, default: false

  defp graph_cell(assigns) do
    assigns =
      assign(
        assigns,
        :head?,
        not is_nil(assigns.row.commit) and assigns.row.commit.id == assigns.head
      )

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
          r={if @head? or @pending, do: 5, else: 4}
          class={lane_color(@row.color)}
          fill={if @pending, do: "var(--color-app)", else: "currentColor"}
          stroke={if @pending, do: "currentColor", else: "var(--color-app)"}
          stroke-width={if @head? or @pending, do: 2, else: 0}
          stroke-dasharray={if @pending, do: "3 2"}
        />
      </svg>
    </span>
    """
  end

  attr :commit, :map, required: true
  attr :refs, :list, required: true, doc: "the commit's labels, from `ref_labels/1`"
  attr :selected_branch, :string, default: nil
  attr :menu, :map, default: nil

  defp ref_column(assigns) do
    assigns =
      assigns
      |> assign(:primary, hd(assigns.refs))
      |> assign(:rest, tl(assigns.refs))
      |> assign(:pinned?, ref_menu_open?(assigns.menu, assigns.refs))

    ~H"""
    <div
      id={"git-ref-column-#{@commit.id}"}
      phx-hook=".RefList"
      class="relative hidden h-full shrink-0 items-center justify-end gap-1 @[44rem]:flex"
      style={ref_column_style()}
    >
      <%!-- Collapsed: the ref that matters most, cut short if its name does
            not fit, plus how many sit behind it. Hovering unfolds every ref
            into a column over the rows below, starting where the stack sits,
            so each one can be read in full, picked, or right clicked for its
            own menu. --%>
      <div data-ref-stack class="flex min-w-0 items-center gap-1">
        <.ref_button
          ref={@primary}
          selected_branch={@selected_branch}
          id={"git-ref-#{slug(@primary.full_name)}"}
        />
        <span
          :if={@rest != []}
          title={Enum.map_join(@rest, ", ", & &1.name)}
          class="shrink-0 rounded border border-line bg-deep px-1 py-px font-mono text-[10px] leading-4 text-faint"
        >
          +{length(@rest)}
        </span>
      </div>

      <div
        id={"git-refs-#{@commit.id}"}
        data-ref-list
        data-pinned={@pinned?}
        class="fixed left-0 top-0 z-40 hidden max-h-[calc(100vh-1rem)] w-max max-w-80 flex-col items-end gap-1 overflow-y-auto rounded-md border border-line bg-panel p-1 shadow-xl shadow-black/20 data-open:flex data-up:flex-col-reverse dark:shadow-black/50"
      >
        <.ref_button
          :for={ref <- @refs}
          ref={ref}
          selected_branch={@selected_branch}
          id={"git-ref-all-#{slug(ref.full_name)}"}
        />
      </div>
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".RefList">
      export default {
        mounted() {
          this.hovered = false
          this.focused = false
          this.timer = null

          // The list is a child of the column, so the pointer counts as inside
          // while it moves from the chip into the list, even though the list is
          // drawn over the rows below.
          this.el.addEventListener("mouseenter", () => { this.hovered = true; this.sync() })
          this.el.addEventListener("mouseleave", () => { this.hovered = false; this.sync() })
          this.el.addEventListener("focusin", () => { this.focused = true; this.sync() })
          this.el.addEventListener("focusout", (event) => {
            this.focused = this.el.contains(event.relatedTarget)
            this.sync()
          })
          this.el.addEventListener("keydown", (event) => {
            if (event.key !== "Escape" || !this.open) return
            this.hovered = this.focused = false
            this.hide()
          })

          // The list is placed against the row, so it would drift away from it
          // as the graph scrolls. Scrolling a long list itself is fine.
          this.onScroll = (event) => {
            if (this.list()?.contains(event.target)) return
            this.hovered = this.focused = false
            this.hide()
          }
          window.addEventListener("scroll", this.onScroll, {capture: true, passive: true})
        },

        // A patch puts the server's markup back, which folds the list away. The
        // pointer has not moved, so unfold it again, picking up the new state,
        // then follow the pin in case a menu from here just opened or closed.
        updated() {
          if (this.open) this.show()
          this.sync()
        },

        destroyed() {
          clearTimeout(this.timer)
          window.removeEventListener("scroll", this.onScroll, {capture: true})
        },

        // Open at once, but give the pointer a moment to come back before
        // folding, so brushing past the edge does not snap the list shut. While
        // a menu opened from one of the chips is up, the list stays put: the
        // pointer has to leave it to reach that menu.
        sync() {
          clearTimeout(this.timer)
          const wanted = this.hovered || this.focused || this.list()?.hasAttribute("data-pinned")
          if (wanted && this.hidesSomething()) {
            if (!this.open) this.show()
          } else {
            this.timer = setTimeout(() => this.hide(), 120)
          }
        },

        list() { return this.el.querySelector("[data-ref-list]") },

        // A lone label that fits has nothing more to show; one whose name was
        // cut short unfolds to show all of it.
        hidesSomething() {
          const list = this.list()
          if (!list) return false
          if (list.children.length > 1) return true

          const name = this.el.querySelector("[data-ref-stack] [data-ref-name]")
          return !!name && name.scrollWidth > name.clientWidth
        },

        show() {
          const list = this.list()
          if (!list) return

          this.open = true
          list.dataset.open = ""
          delete list.dataset.up

          // Parking it at 0,0 first reveals where its containing block starts and
          // the scale the interface is drawn at, the same way the menus do it.
          list.style.left = "0px"
          list.style.top = "0px"

          const origin = list.getBoundingClientRect()
          const scale = (list.offsetWidth && origin.width / list.offsetWidth) || 1
          const anchor = this.el.getBoundingClientRect()
          const margin = 8
          const lastX = Math.max(margin, window.innerWidth - origin.width - margin)
          const x = Math.min(Math.max(margin, anchor.right - origin.width), lastX)

          // The list opens over the stack, so its first chip lands on the one
          // that was showing. Near the bottom it grows upwards instead, reversed
          // so that chip still sits on the row.
          const up = anchor.top + origin.height + margin > window.innerHeight
          if (up) list.dataset.up = ""
          const y = up ? Math.max(margin, anchor.bottom - origin.height) : anchor.top

          list.style.left = `${(x - origin.left) / scale}px`
          list.style.top = `${(y - origin.top) / scale}px`
        },

        hide() {
          this.open = false
          const list = this.list()
          if (!list) return

          delete list.dataset.open
          delete list.dataset.up
        }
      }
    </script>
    """
  end

  attr :ref, :map, required: true
  attr :selected_branch, :string, default: nil
  attr :id, :string, required: true

  defp ref_button(%{ref: %Tag{}} = assigns) do
    ~H"""
    <span class="flex min-w-0 max-w-full"><.label_chip label={@ref} /></span>
    """
  end

  defp ref_button(assigns) do
    assigns = assign(assigns, :selected?, label_selected?(assigns.ref, assigns.selected_branch))

    ~H"""
    <button
      type="button"
      id={@id}
      data-menu-kind="branch"
      data-menu-id={@ref.full_name}
      phx-click="select_branch"
      phx-value-name={@ref.full_name}
      aria-pressed={to_string(@selected?)}
      title={chip_title(@ref)}
      class={[
        "flex min-w-0 max-w-full cursor-pointer rounded transition-shadow",
        "focus-visible:outline-2 focus-visible:outline-accent",
        @selected? && "ring-1 ring-accent/60"
      ]}
    >
      <.label_chip label={@ref} />
    </button>
    """
  end

  # Whether the open menu belongs to one of these chips, rather than to the same
  # branch opened from the branch panel.
  defp ref_menu_open?(%{kind: :branch, id: id, anchor: anchor}, refs) do
    anchor in ["git-ref-#{slug(id)}", "git-ref-all-#{slug(id)}"] and
      Enum.any?(refs, &(&1.full_name == id))
  end

  defp ref_menu_open?(_menu, _refs), do: false

  @doc """
  The labels of one commit, in the order a reader looks for them.

  A local branch and the remote branches of the same name on one commit are one
  label: the name, and where it lives. Picking the label, or opening its menu,
  means the local branch when there is one. The branch HEAD is on comes first,
  then the trunk names a project is most likely to care about, then the
  remaining branches, and finally tags.
  """
  def ref_labels(labels) do
    {tags, branches} = Enum.split_with(labels, &match?(%Tag{}, &1))

    branches
    |> Enum.group_by(&remote_branch_name/1)
    |> Enum.map(fn {name, branches} -> branch_label(name, branches) end)
    |> Kernel.++(tags)
    |> Enum.sort_by(&ref_rank/1)
  end

  defp branch_label(name, branches) do
    {locals, remotes} = Enum.split_with(branches, &(&1.kind == :local))
    local = List.first(locals)
    remotes = Enum.sort_by(remotes, & &1.name)

    %{
      name: name,
      full_name: (local || hd(remotes)).full_name,
      local: local,
      remotes: remotes,
      current?: match?(%{current?: true}, local)
    }
  end

  # Selecting any branch a label stands for, here or in the branch panel,
  # marks the label.
  defp label_selected?(%{local: local, remotes: remotes}, selected_branch) do
    Enum.any?([local | remotes], &(&1 && &1.full_name == selected_branch))
  end

  defp ref_rank(%Tag{name: name}), do: {3, 0, String.downcase(name)}
  defp ref_rank(%{current?: true, name: name}), do: {0, 0, String.downcase(name)}

  defp ref_rank(%{local: local, name: name}) do
    group = if local, do: 1, else: 2
    {group, trunk_rank(name), String.downcase(name)}
  end

  @trunks ~w(master main dev)

  defp trunk_rank(name) do
    case Enum.find_index(@trunks, &(&1 == String.downcase(name))) do
      nil -> length(@trunks)
      index -> index
    end
  end

  attr :label, :map, required: true, doc: "a tag, or a branch label from `ref_labels/1`"

  defp label_chip(%{label: %Tag{}} = assigns) do
    ~H"""
    <span
      title={chip_title(@label)}
      class={[chip_base(), "border-warn/50 bg-warn-soft/40 text-warn-strong"]}
    >
      <.icon name="hero-tag-micro" class="size-2.5 shrink-0" />
      <span data-ref-name class="truncate">{@label.name}</span>
    </span>
    """
  end

  # The name carries the label; a tick in front says HEAD is on it, and quieter
  # marks behind it say where it lives: a monitor for this machine, a cloud for
  # a remote.
  defp label_chip(assigns) do
    ~H"""
    <span title={chip_title(@label)} class={[chip_base(), chip_tone(@label)]}>
      <.icon :if={@label.current?} name="hero-check-micro" class="size-2.5 shrink-0" />
      <span data-ref-name class="truncate">{@label.name}</span>
      <span class="flex shrink-0 items-center gap-px opacity-70" aria-hidden="true">
        <.icon :if={@label.local} name="hero-computer-desktop-micro" class="size-2.5" />
        <.icon :if={@label.remotes != []} name="hero-cloud-micro" class="size-2.5" />
      </span>
    </span>
    """
  end

  defp chip_base,
    do:
      "flex min-w-0 shrink items-center gap-1 rounded border px-1 py-px font-mono text-[10px] leading-4"

  defp chip_tone(%{current?: true}), do: "border-ok/60 bg-ok-soft/60 text-ok-strong"
  defp chip_tone(%{local: nil}), do: "border-violet/50 bg-violet/10 text-violet-strong"
  defp chip_tone(_label), do: "border-accent/50 bg-accent-soft/70 text-accent-strong"

  defp chip_title(%Tag{annotated?: true, name: name}), do: "Annotated tag #{name}"
  defp chip_title(%Tag{name: name}), do: "Tag #{name}"

  defp chip_title(%{local: nil, remotes: [remote]}), do: "Remote branch #{remote.name}"

  defp chip_title(%{local: nil, remotes: remotes}),
    do: "Remote branches #{Enum.map_join(remotes, ", ", & &1.name)}"

  defp chip_title(%{local: local, remotes: remotes}) do
    kind = if local.current?, do: "Current branch", else: "Local branch"

    case remotes do
      [] ->
        "#{kind} #{local.name}"

      remotes ->
        "#{kind} #{local.name}, same commit as #{Enum.map_join(remotes, ", ", & &1.name)}"
    end
  end

  # The branch panel sorts branches under Local and Remote, and keeps the mark
  # in front of the name.
  defp branch_icon(%{kind: :remote}), do: "hero-cloud-micro"
  defp branch_icon(_branch), do: "hero-computer-desktop-micro"

  attr :commit, :map, required: true
  attr :tab, :map, required: true

  defp commit_menu(assigns) do
    picked = for c <- assigns.tab.snapshot.commits, c.id in assigns.tab.selected_commits, do: c

    if length(picked) > 1 and assigns.commit.id in assigns.tab.selected_commits do
      commits_menu(assign(assigns, :picked, picked))
    else
      single_commit_menu(assigns)
    end
  end

  # What can be done to every picked commit at once, each entry counting them.
  defp commits_menu(assigns) do
    assigns = assign(assigns, :squash_blocker, squash_blocker(assigns.tab, assigns.picked))

    ~H"""
    <.context_menu
      id="git-commits-menu"
      anchor={@tab.menu[:anchor] || "git-commit-menu-button-#{@commit.id}"}
      at={@tab.menu[:at]}
      label={"Actions for #{commits_label(length(@picked))}"}
    >
      <.menu_item
        id="git-menu-cherry-pick-commits"
        icon="hero-sparkles"
        phx-click="request"
        phx-value-action="cherry_pick_selection"
      >
        Cherry-pick {commits_label(length(@picked))}
      </.menu_item>
      <.menu_item
        id="git-menu-squash-commits"
        icon="hero-rectangle-stack"
        disabled={not is_nil(@squash_blocker)}
        title={@squash_blocker}
        phx-click="prepare"
        phx-value-action="squash"
      >
        Squash {commits_label(length(@picked))}…
      </.menu_item>
      <p
        :if={@squash_blocker}
        id="git-squash-blocker"
        class="px-2 pb-1.5 pl-7.5 text-[10px] leading-snug text-faint"
      >
        {@squash_blocker}
      </p>
    </.context_menu>
    """
  end

  # The server checks all of this again; the menu only avoids offering a squash
  # that is bound to be refused.
  defp squash_blocker(tab, picked) do
    line =
      tab
      |> first_parent_line()
      |> Stream.drop_while(&(&1 not in picked))
      |> Enum.take(length(picked))

    cond do
      tab.snapshot.detached? ->
        "Check out a branch to squash commits on it."

      MapSet.new(line) != MapSet.new(picked) or Enum.any?(picked, &match?([_, _ | _], &1.parents)) ->
        "Only consecutive commits on #{current_label(tab)}, without merges, can be squashed."

      tab.changes != [] ->
        "Commit or stash the working tree changes first."

      true ->
        nil
    end
  end

  # HEAD, its first parent, that one's first parent, and so on down the graph.
  defp first_parent_line(tab) do
    Stream.unfold(tab.snapshot.head, fn
      nil -> nil
      id -> with %{} = commit <- tab.commits_by_id[id], do: {commit, List.first(commit.parents)}
    end)
  end

  defp commits_label(1), do: "1 commit"
  defp commits_label(count), do: "#{count} commits"

  defp single_commit_menu(assigns) do
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
      <% {:file, file} -> %>
        <.file_menu file={file} side={@tab.menu.side} tab={@tab} />
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

  defp menu_target(%{menu: %{kind: :file, id: path}} = tab) do
    case Enum.find(tab.changes, &(&1.path == path)) do
      nil -> nil
      file -> {:file, file}
    end
  end

  defp menu_target(_tab), do: nil

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
          label="Working tree"
          icon="hero-pencil-square"
          count={length(@tab.changes)}
        />
      </div>

      <div class="min-h-0 flex-1 overflow-y-auto">
        <.operation_banner :if={@tab.snapshot.operation} tab={@tab} />
        <div :if={@tab.notices != []} id="git-notices" class="m-2.5 space-y-2.5">
          <%= for notice <- ordered_notices(@tab.notices) do %>
            <.error_notice
              :if={notice.kind == :error}
              id={"git-notice-#{notice.id}"}
              error={notice.content}
              dismiss_id={notice.id}
              class=""
            />
            <.result_notice :if={notice.kind == :success} notice={notice} />
          <% end %>
        </div>
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

  defp ordered_notices(notices) do
    Enum.filter(notices, &(&1.kind == :error)) ++
      Enum.filter(notices, &(&1.kind == :success))
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
      <div
        :if={MapSet.size(@tab.selected_commits) > 1}
        id="git-commit-selection"
        class="flex items-center gap-1 rounded-md border border-accent/30 bg-accent-soft/30 px-2 py-1"
      >
        <span class="min-w-0 flex-1 truncate text-[11px] text-muted">
          <span class="font-semibold text-ink">
            {commits_label(MapSet.size(@tab.selected_commits))} selected
          </span>
          · right click one for actions
        </span>
        <button
          type="button"
          id="git-clear-commits"
          phx-click="clear_commits"
          class="shrink-0 cursor-pointer rounded px-1.5 py-0.5 text-[11px] text-muted transition-colors hover:bg-hover hover:text-ink focus-visible:outline-2 focus-visible:outline-accent"
        >
          Clear
        </button>
      </div>

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
        <.label_chip :for={label <- ref_labels(@commit.labels)} label={label} />
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

      <.commit_changes
        commit={@commit.id}
        loaded={@tab.commit_changes}
        diff={@tab.diff}
      />
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

      <label :if={@action.kind not in [:edit_message, :squash]} class="flex flex-col gap-1">
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

      <label :if={@action.kind in [:edit_message, :squash]} class="flex flex-col gap-1">
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

  ## Commit changes

  @doc """
  The files one commit touched, shown under its metadata.

  Picking a file opens what that commit did to it, over the graph.
  """
  attr :commit, :string, required: true
  attr :loaded, :map, default: nil
  attr :diff, :map, default: nil

  def commit_changes(assigns) do
    ~H"""
    <div id="git-commit-changes">
      <div class="mb-1 flex items-center gap-1.5">
        <span class="text-[10px] font-semibold uppercase tracking-wide text-muted">
          Files changed
        </span>
        <span :if={@loaded} class="font-mono text-[10px] text-faint">
          ({length(@loaded.files)})
        </span>
      </div>

      <%= cond do %>
        <% is_nil(@loaded) -> %>
          <p id="git-commit-changes-loading" class="flex items-center gap-2 text-[11px] text-muted">
            <.icon name="hero-arrow-path" class="size-3.5 text-accent motion-safe:animate-spin" />
            Reading the commit…
          </p>
        <% @loaded.error -> %>
          <.error_notice id="git-commit-changes-error" error={@loaded.error} class="" />
        <% @loaded.files == [] -> %>
          <p id="git-commit-changes-empty" class="text-[11px] text-faint">
            This commit changed no files.
          </p>
        <% true -> %>
          <div id="git-commit-files" role="listbox" aria-label="Files changed">
            <.commit_file_row
              :for={file <- @loaded.files}
              file={file}
              commit={@commit}
              diff={@diff}
            />
          </div>
      <% end %>
    </div>
    """
  end

  attr :file, :map, required: true
  attr :commit, :string, required: true
  attr :diff, :map, default: nil

  defp commit_file_row(assigns) do
    assigns = assign(assigns, :open?, open_diff?(assigns.diff, assigns.file.path, :commit))

    ~H"""
    <button
      type="button"
      id={"git-commit-file-#{slug(@file.path)}"}
      role="option"
      aria-selected={to_string(@open?)}
      phx-click="view_diff"
      phx-value-path={@file.path}
      phx-value-side="commit"
      phx-value-commit={@commit}
      title={"View what this commit did to #{@file.path}"}
      class={[
        "flex w-full cursor-pointer items-center gap-2 rounded px-1.5 py-1 text-left transition-colors",
        "focus-visible:outline-2 focus-visible:-outline-offset-2 focus-visible:outline-accent",
        if(@open?, do: "bg-active", else: "hover:bg-hover")
      ]}
    >
      <span class={[
        "w-4 shrink-0 text-center font-mono text-[10px] font-bold",
        state_color(@file.staged)
      ]}>
        {state_code(@file.staged)}
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
      <.icon name="hero-document-magnifying-glass" class="size-3.5 shrink-0 text-faint" />
    </button>
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
    <%!-- Rows are picked by clicking them, and a right click on one opens what
          can be done to everything picked. --%>
    <div
      id="git-working-tree"
      phx-hook="MDTClientWeb.PanelComponents.RowMenu"
      data-select-all="select_all_paths"
      class="flex flex-col gap-3 p-2.5"
    >
      <%!-- Both sides stay on screen whatever the counts are, so the shape of
            the panel never changes underneath the pointer. --%>
      <.file_section
        id="git-unstaged"
        title="Unstaged files"
        files={@unstaged}
        side={:unstaged}
        tab={@tab}
        empty="Nothing to stage."
        action="stage_all"
        action_label="Stage all"
      />
      <.file_section
        id="git-staged"
        title="Staged files"
        files={@staged}
        side={:staged}
        tab={@tab}
        empty="Nothing staged yet."
        action="unstage_all"
        action_label="Unstage all"
      />

      <div
        :if={@tab.changes != [] and not @tab.stashing?}
        id="git-selection"
        class="flex items-center gap-1 px-0.5"
      >
        <span class="min-w-0 flex-1 truncate text-[10px] text-faint">
          <%= if @selection == 0 do %>
            Click to select, Shift or Ctrl to add more
          <% else %>
            <span class="font-semibold text-muted">{@selection} selected</span>
            · right click for actions
          <% end %>
        </span>
        <button
          type="button"
          id="git-select-all-paths"
          phx-click="select_all_paths"
          class="shrink-0 cursor-pointer rounded px-1.5 py-0.5 text-[11px] text-muted transition-colors hover:bg-hover hover:text-ink focus-visible:outline-2 focus-visible:outline-accent"
        >
          Select all
        </button>
        <button
          type="button"
          id="git-clear-paths"
          phx-click="clear_paths"
          disabled={@selection == 0}
          class="shrink-0 cursor-pointer rounded px-1.5 py-0.5 text-[11px] text-muted transition-colors hover:bg-hover hover:text-ink disabled:cursor-not-allowed disabled:opacity-40 focus-visible:outline-2 focus-visible:outline-accent"
        >
          Clear
        </button>
      </div>

      <%!-- Stashing is picked from the file menu; the message only matters once
            it is the decision, so it stays out of the way until then. --%>
      <form
        :if={@tab.stashing?}
        id="git-stash-form"
        phx-submit="stash_selected"
        class="flex flex-col gap-1.5 rounded-md border border-line-soft p-2"
      >
        <span class="text-[10px] uppercase tracking-wide text-faint">
          Stash {files_label(@selection)}
        </span>
        <input
          type="text"
          name="message"
          id="git-stash-message"
          value={@tab.stash_message}
          placeholder="Stash message (optional)"
          aria-label="Stash message"
          phx-mounted={JS.focus()}
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
        <div class="flex items-center justify-end gap-1.5">
          <.button
            type="button"
            id="git-cancel-stash"
            phx-click="cancel_stash"
            variant="ghost"
            class="px-2 py-1 text-[11px]"
          >
            Cancel
          </.button>
          <.button
            type="submit"
            id="git-stash-selected"
            disabled={@selection == 0 or not is_nil(@tab.pending)}
            variant="primary"
            class="px-2 py-1 text-[11px]"
          >
            Stash {files_label(@selection)}
          </.button>
        </div>
      </form>

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
    </div>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :files, :list, required: true
  attr :side, :atom, required: true
  attr :tab, :map, required: true
  attr :empty, :string, required: true
  attr :action, :string, required: true
  attr :action_label, :string, required: true

  defp file_section(assigns) do
    ~H"""
    <div>
      <div class="mb-1 flex items-center gap-1.5 px-0.5">
        <span class="text-[10px] font-semibold uppercase tracking-wider text-muted">{@title}</span>
        <span class="font-mono text-[10px] text-faint">({length(@files)})</span>
        <div class="flex-1"></div>
        <button
          type="button"
          id={"#{@id}-all"}
          phx-click="request"
          phx-value-action={@action}
          disabled={@files == [] or not is_nil(@tab.pending)}
          class="cursor-pointer rounded border border-line-soft px-1.5 py-0.5 text-[10px] text-muted transition-colors hover:bg-hover hover:text-ink disabled:cursor-not-allowed disabled:opacity-40 focus-visible:outline-2 focus-visible:outline-accent"
        >
          {@action_label}
        </button>
      </div>
      <p :if={@files == []} id={"#{@id}-empty"} class="px-1.5 py-1 text-[11px] text-faint">
        {@empty}
      </p>
      <div id={@id} role="listbox" aria-multiselectable="true" aria-label={@title}>
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
      |> assign(:open?, open_diff?(assigns.tab.diff, assigns.file.path, assigns.side))

    ~H"""
    <div
      id={"git-file-row-#{@side}-#{slug(@file.path)}"}
      data-menu-kind="file"
      data-menu-id={@file.path}
      data-menu-side={@side}
      class={[
        "group flex select-none items-center gap-1 rounded pr-1 transition-colors",
        cond do
          @selected -> "bg-accent-soft text-ink"
          @open? -> "bg-active"
          true -> "hover:bg-hover"
        end,
        @open? && "shadow-[inset_2px_0_0_0_var(--color-accent)]"
      ]}
      style="content-visibility: auto; contain-intrinsic-size: 0 28px;"
    >
      <button
        type="button"
        id={"git-file-#{@side}-#{slug(@file.path)}"}
        role="option"
        aria-selected={to_string(@selected)}
        phx-click="select_path"
        phx-value-path={@file.path}
        phx-value-side={@side}
        class="flex min-w-0 flex-1 cursor-pointer items-center gap-2 px-1.5 py-1 text-left focus-visible:outline-2 focus-visible:-outline-offset-2 focus-visible:outline-accent"
      >
        <span class={[
          "w-4 shrink-0 text-center font-mono text-[10px] font-bold",
          state_color(@state)
        ]}>
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

      <button
        type="button"
        id={"git-diff-#{@side}-#{slug(@file.path)}"}
        phx-click="view_diff"
        phx-value-path={@file.path}
        phx-value-side={@side}
        title={"View the #{@side} diff of #{@file.path}"}
        aria-label={"View the #{@side} diff of #{@file.path}"}
        class={[
          "flex size-5 shrink-0 cursor-pointer items-center justify-center rounded transition-all",
          "hover:bg-panel hover:text-accent focus:opacity-100 focus-visible:outline-2 focus-visible:outline-accent",
          "group-hover:opacity-100",
          if(@open?, do: "text-accent opacity-100", else: "text-faint opacity-0")
        ]}
      >
        <.icon name="hero-document-magnifying-glass" class="size-3.5" />
      </button>

      <button
        type="button"
        id={"git-move-#{@side}-#{slug(@file.path)}"}
        phx-click="request"
        phx-value-action={if @side == :staged, do: "unstage_path", else: "stage_path"}
        phx-value-path={@file.path}
        disabled={not is_nil(@tab.pending)}
        title={if @side == :staged, do: "Unstage #{@file.path}", else: "Stage #{@file.path}"}
        aria-label={if @side == :staged, do: "Unstage #{@file.path}", else: "Stage #{@file.path}"}
        class="flex size-5 shrink-0 cursor-pointer items-center justify-center rounded text-faint opacity-0 transition-all hover:bg-panel hover:text-ink focus:opacity-100 disabled:cursor-not-allowed focus-visible:outline-2 focus-visible:outline-accent group-hover:opacity-100"
      >
        <.icon
          name={if @side == :staged, do: "hero-minus-circle", else: "hero-plus-circle"}
          class="size-3.5"
        />
      </button>
    </div>
    """
  end

  defp open_diff?(%{path: path, side: side}, path, side), do: true
  defp open_diff?(_diff, _path, _side), do: false

  attr :file, :map, required: true, doc: "the file the menu was opened on"
  attr :side, :atom, required: true
  attr :tab, :map, required: true

  # What to do with everything picked comes first, each entry counting the files
  # it would touch; what to do with the one file under the pointer follows.
  defp file_menu(assigns) do
    selected =
      Enum.filter(assigns.tab.changes, &MapSet.member?(assigns.tab.selected_paths, &1.path))

    assigns =
      assigns
      |> assign(:count, length(selected))
      |> assign(:stageable, Enum.count(selected, &FileChange.unstaged?/1))
      |> assign(:unstageable, Enum.count(selected, &FileChange.staged?/1))

    ~H"""
    <.context_menu
      id="git-file-menu"
      anchor={@tab.menu[:anchor] || "git-file-row-#{@side}-#{slug(@file.path)}"}
      at={@tab.menu[:at]}
      label={"Actions for #{files_label(@count)}"}
    >
      <.menu_item
        :if={@stageable > 0}
        id="git-menu-stage-files"
        icon="hero-plus-circle"
        phx-click="request"
        phx-value-action="stage"
      >
        Stage {files_label(@stageable)}
      </.menu_item>
      <.menu_item
        :if={@unstageable > 0}
        id="git-menu-unstage-files"
        icon="hero-minus-circle"
        phx-click="request"
        phx-value-action="unstage"
      >
        Unstage {files_label(@unstageable)}
      </.menu_item>
      <.menu_item
        id="git-menu-stash-files"
        icon="hero-archive-box-arrow-down"
        phx-click="prepare_stash"
      >
        Stash {files_label(@count)}…
      </.menu_item>
      <.menu_item
        id="git-menu-discard-files"
        icon="hero-arrow-uturn-left"
        danger
        phx-click="request"
        phx-value-action="discard"
      >
        Discard {files_label(@count)}…
      </.menu_item>

      <.menu_separator />

      <.menu_item
        id="git-menu-view-file"
        icon="hero-document-magnifying-glass"
        phx-click="view_diff"
        phx-value-path={@file.path}
        phx-value-side={@side}
      >
        View changes to {Path.basename(@file.path)}
      </.menu_item>
      <.menu_item
        id="git-menu-copy-path"
        icon="hero-clipboard-document"
        phx-hook=".Copy"
        data-copy={@file.path}
        phx-click="close_menu"
      >
        Copy path
      </.menu_item>
    </.context_menu>
    """
  end

  defp files_label(1), do: "1 file"
  defp files_label(count), do: "#{count} files"

  attr :tab, :map, required: true

  def stash_list(assigns) do
    ~H"""
    <div class="shrink-0 border-t border-line-soft">
      <button
        type="button"
        id="git-stashes-toggle"
        phx-click="toggle_stashes"
        aria-expanded={to_string(@tab.stashes_open?)}
        aria-controls="git-stashes"
        class="flex w-full cursor-pointer items-center gap-1.5 px-2.5 py-1.5 text-left transition-colors hover:bg-hover focus-visible:outline-2 focus-visible:-outline-offset-2 focus-visible:outline-accent"
      >
        <.icon
          name="hero-chevron-right"
          class={["size-3 text-faint transition-transform", @tab.stashes_open? && "rotate-90"]}
        />
        <span class="text-[10px] font-semibold uppercase tracking-wider text-muted">Stashes</span>
        <span class="font-mono text-[10px] text-faint">({length(@tab.stashes)})</span>
      </button>

      <div :if={@tab.stashes_open?} class="max-h-52 overflow-y-auto px-1.5 pb-2">
        <p :if={@tab.stashes == []} id="git-stashes-empty" class="px-1 py-1 text-[11px] text-faint">
          Nothing stashed yet.
        </p>

        <div :if={@tab.stashes != []} id="git-stashes" class="flex flex-col gap-1">
          <div
            :for={stash <- @tab.stashes}
            id={"git-stash-#{stash.index}"}
            class="group rounded-md border border-line-soft p-1.5 transition-colors hover:border-line"
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
                title="Restore the complete stash and keep it in the list"
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
                title="Restore the complete stash and remove it from the list"
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
                title="Delete the stash without restoring it"
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
    </div>
    """
  end

  ## Notices and dialogs

  attr :id, :string, default: nil
  attr :error, :map, required: true
  attr :class, :any, default: "mt-4"
  attr :dismiss_id, :string, default: nil

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
      <button
        :if={@dismiss_id}
        type="button"
        id={"git-dismiss-notice-#{@dismiss_id}"}
        phx-click="dismiss_notice"
        phx-value-id={@dismiss_id}
        title="Dismiss"
        aria-label="Dismiss error"
        class="flex size-5 shrink-0 cursor-pointer items-center justify-center rounded text-faint transition-colors hover:bg-hover hover:text-ink"
      >
        <.icon name="hero-x-mark" class="size-3.5" />
      </button>
    </div>
    """
  end

  attr :notice, :map, required: true

  def result_notice(assigns) do
    ~H"""
    <div
      id={"git-notice-#{@notice.id}"}
      role="status"
      phx-hook="NoticeTimer"
      data-notice-id={@notice.id}
      data-timeout="6000"
      class="flex items-start gap-2 rounded-md border border-ok/30 bg-ok-soft/20 p-2.5"
    >
      <.icon name="hero-check-circle" class="mt-px size-4 shrink-0 text-ok" />
      <div class="min-w-0 flex-1">
        <p class="text-[11px] font-semibold text-ok">{result_title(@notice.content)}</p>
        <pre
          :if={@notice.content.output != ""}
          class="mt-0.5 max-h-28 overflow-auto whitespace-pre-wrap break-words font-mono text-[11px] leading-relaxed text-muted"
          phx-no-curly-interpolation
        ><%= @notice.content.output %></pre>
      </div>
      <button
        type="button"
        id={"git-dismiss-notice-#{@notice.id}"}
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
            <p id="git-confirm-title" class="break-words text-[13px] font-semibold text-ink">
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

  defp ssh_label(%{repository: %{ssh_key: nil}}), do: "SSH keys"
  defp ssh_label(_tab), do: "SSH ready"

  defp branches(tab, kind) do
    filter = String.downcase(String.trim(tab.filter))

    tab.snapshot.branches
    |> Enum.filter(&(&1.kind == kind))
    |> Enum.filter(&(filter == "" or String.contains?(String.downcase(&1.full_name), filter)))
    |> Enum.sort_by(&{not &1.current?, &1.name})
  end

  defp head?(%{snapshot: %{head: head}}, %{id: id}), do: head == id
  defp head?(_tab, _commit), do: false

  defp menu_open?(%{menu: menu}, kind, id), do: menu_open?(menu, kind, id)
  defp menu_open?(%{kind: kind, id: id}, kind, id), do: true
  defp menu_open?(_menu_or_tab, _kind, _id), do: false

  defp selected_commit(%{selected_commit: nil}), do: nil

  defp selected_commit(%{selected_commit: id, commits_by_id: commits_by_id}) do
    Map.get(commits_by_id, id)
  end

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
  defp action_title(%{kind: :squash, target: ids}), do: "Squash #{commits_label(length(ids))}"

  defp action_field(%{kind: :rename_branch}), do: "New name"
  defp action_field(%{kind: :checkout_remote}), do: "Local branch name"
  defp action_field(_action), do: "Branch name"

  defp action_submit(%{kind: :create_branch}), do: "Create"
  defp action_submit(%{kind: :rename_branch}), do: "Rename"
  defp action_submit(%{kind: :checkout_remote}), do: "Check out"
  defp action_submit(%{kind: :edit_message}), do: "Save message"
  defp action_submit(%{kind: :squash, target: ids}), do: "Squash #{commits_label(length(ids))}"

  defp action_hint(%{kind: :create_branch}),
    do: "The new branch starts at the commit shown below."

  defp action_hint(%{kind: :rename_branch}),
    do: "Only the local branch is renamed; its upstream is left alone."

  defp action_hint(%{kind: :checkout_remote}),
    do: "A local branch is created tracking the remote one, then checked out."

  defp action_hint(%{kind: :squash}),
    do:
      "The commits become one, keeping the oldest one's author, with the message " <>
        "below. Every commit after them is rewritten, so their object ids change."

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
