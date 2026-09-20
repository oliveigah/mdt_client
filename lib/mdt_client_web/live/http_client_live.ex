defmodule MDTClientWeb.HttpClientLive do
  @moduledoc """
  The HTTP client tool: a searchable history on the left, tabbed requests and
  their responses on the right.

  All data is mocked (see `MDTClient.HttpClient`) and lives in the LiveView
  assigns, so nothing is persisted between sessions yet.
  """
  use MDTClientWeb, :live_view

  alias MDTClient.HttpClient
  alias MDTClient.HttpClient.Curl
  alias MDTClient.Tools

  @impl true
  def mount(_params, _session, socket) do
    tabs = HttpClient.sample_tabs()

    {:ok,
     socket
     |> assign(:page_title, "HTTP Client")
     |> assign(:tool, Tools.fetch!(:http))
     |> assign(:tabs, tabs)
     |> assign(:active_id, hd(tabs).id)
     |> assign(:sidebar?, true)
     |> assign(:collapsed, MapSet.new())
     |> assign(:dialog, nil)
     |> assign(:import_error, nil)
     |> assign(:term, "")
     |> assign(:history, HttpClient.history())
     |> assign_history()
     |> sync_tab()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} tool={@tool}>
      <div
        class="flex min-h-0 flex-1 overflow-hidden"
        phx-window-keydown="maybe_send"
        phx-key="Enter"
      >
        <.history_panel
          :if={@sidebar?}
          groups={@groups}
          term={@term}
          count={@count}
          collapsed={@collapsed}
          active_source={@tab && @tab.source_id}
        />

        <.resizer
          :if={@sidebar?}
          id="history-resizer"
          panel="history-panel"
          variable="--history-width"
          storage_key="mdt:history-width"
          axis="x"
          min="180"
          max="520"
        />

        <section class="flex min-w-0 flex-1 flex-col bg-app">
          <.tab_bar tabs={@tabs} active_id={@active_id} sidebar?={@sidebar?} />

          <%= if @tab do %>
            <.request_editor tab={@tab} form={@form} />

            <.resizer
              id="request-resizer"
              panel="request-editor"
              variable="--request-height"
              storage_key="mdt:request-height"
              axis="y"
              min="96"
              max="700"
            />

            <.response_panel tab={@tab} />
          <% else %>
            <div class="flex flex-1 flex-col items-center justify-center gap-3 text-center">
              <span class="flex size-10 items-center justify-center rounded-xl border border-line bg-panel text-muted">
                <.icon name="hero-bolt" class="size-5" />
              </span>
              <div>
                <p class="text-sm">No request open</p>
                <p class="text-xs text-muted">Open one from the history or start a new one.</p>
              </div>
              <.button phx-click="new_tab" variant="secondary">
                <.icon name="hero-plus" class="size-4" /> New request
              </.button>
            </div>
          <% end %>
        </section>
      </div>

      <.curl_dialog
        :if={@dialog}
        dialog={@dialog}
        tab={@tab}
        import_error={@import_error}
      />
    </Layouts.app>
    """
  end

  ## curl import and export

  attr :dialog, :string, required: true
  attr :tab, :map, default: nil
  attr :import_error, :string, default: nil

  defp curl_dialog(assigns) do
    ~H"""
    <div
      id="curl-dialog"
      class="fixed inset-0 z-40 flex items-center justify-center p-6"
      phx-window-keydown="close_dialog"
      phx-key="Escape"
    >
      <div class="absolute inset-0 bg-black/50" phx-click="close_dialog"></div>

      <div class="relative flex max-h-full w-full max-w-2xl flex-col overflow-hidden rounded-xl border border-line bg-panel shadow-2xl shadow-black/20 dark:shadow-black/50">
        <div class="flex h-9 shrink-0 items-center gap-2 border-b border-line-soft px-3">
          <.icon name="hero-command-line" class="size-4 text-accent" />
          <span class="text-xs font-semibold">
            {if @dialog == "export_curl", do: "Export as curl", else: "Import from curl"}
          </span>
          <div class="flex-1"></div>
          <button
            type="button"
            phx-click="close_dialog"
            title="Close"
            class="flex size-6 cursor-pointer items-center justify-center rounded text-faint transition-colors hover:bg-hover hover:text-ink"
          >
            <.icon name="hero-x-mark" class="size-4" />
          </button>
        </div>

        <%= if @dialog == "export_curl" do %>
          <pre
            id="curl-export"
            class="max-h-80 overflow-auto whitespace-pre-wrap break-all bg-deep px-3 py-2.5 font-mono text-xs leading-5 text-ink"
          >{Curl.to_curl(@tab)}</pre>

          <div class="flex shrink-0 items-center justify-end gap-2 border-t border-line-soft px-3 py-2.5">
            <.button type="button" phx-click="close_dialog" variant="secondary">Close</.button>
            <.button
              type="button"
              id="copy-curl"
              phx-hook=".Copy"
              data-copy={Curl.to_curl(@tab)}
              variant="primary"
            >
              <.icon name="hero-clipboard-document" class="size-4" />
              <span data-label>Copy</span>
            </.button>
          </div>
        <% else %>
          <form phx-submit="import_curl" class="flex min-h-0 flex-col">
            <textarea
              id="curl-import"
              name="command"
              rows="9"
              spellcheck="false"
              phx-mounted={JS.focus()}
              placeholder="curl https://api.example.com/v1/users -H 'Accept: application/json'"
              class="min-h-0 flex-1 resize-none bg-deep px-3 py-2.5 font-mono text-xs leading-5 text-ink outline-none placeholder:text-faint focus:ring-1 focus:ring-inset focus:ring-accent/30"
            ></textarea>

            <div class="flex shrink-0 items-center gap-2 border-t border-line-soft px-3 py-2.5">
              <p
                :if={@import_error}
                id="curl-import-error"
                class="flex items-center gap-1.5 text-xs text-bad"
              >
                <.icon name="hero-exclamation-circle" class="size-4" />
                {@import_error}
              </p>
              <p :if={!@import_error} class="text-[11px] text-faint">
                The command opens as a new request tab.
              </p>
              <div class="flex-1"></div>
              <.button type="button" phx-click="close_dialog" variant="secondary">Cancel</.button>
              <.button type="submit" variant="primary">Import</.button>
            </div>
          </form>
        <% end %>
      </div>
    </div>
    """
  end

  ## Resizable panels

  # A drag handle that resizes the panel next to it.
  #
  # The size is written to a CSS variable on `<html>` (outside anything LiveView
  # patches) and persisted in local storage, so it survives navigation and
  # restarts. Double clicking restores the default.
  attr :id, :string, required: true
  attr :panel, :string, required: true, doc: "the DOM id of the panel being resized"
  attr :variable, :string, required: true, doc: "the CSS variable holding the size"
  attr :storage_key, :string, required: true
  attr :axis, :string, required: true, values: ~w(x y)
  attr :min, :string, required: true
  attr :max, :string, required: true

  defp resizer(assigns) do
    ~H"""
    <div
      id={@id}
      phx-hook=".Resize"
      phx-update="ignore"
      role="separator"
      aria-orientation={if @axis == "x", do: "vertical", else: "horizontal"}
      title="Drag to resize, double click to reset"
      data-panel={@panel}
      data-variable={@variable}
      data-key={@storage_key}
      data-axis={@axis}
      data-min={@min}
      data-max={@max}
      class={[
        "shrink-0 transition-colors hover:bg-accent/30 data-[dragging]:bg-accent/50",
        if(@axis == "x",
          do:
            "w-1.5 cursor-col-resize border-r border-line-soft hover:border-accent data-[dragging]:border-accent",
          else:
            "h-1.5 cursor-row-resize border-b border-line hover:border-accent data-[dragging]:border-accent"
        )
      ]}
    >
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".Resize">
      export default {
        mounted() {
          this.axis = this.el.dataset.axis
          this.variable = this.el.dataset.variable
          this.storageKey = this.el.dataset.key
          this.min = parseInt(this.el.dataset.min, 10)
          this.max = parseInt(this.el.dataset.max, 10)

          this.onMove = (event) => {
            if (!this.panel) return
            const rect = this.panel.getBoundingClientRect()
            const horizontal = this.axis === "x"
            // Pointer coordinates are in screen pixels while the panel is sized
            // in its own, possibly zoomed, pixels. This ratio converts between them.
            const scale =
              (horizontal ? rect.width / (this.panel.offsetWidth || 1) : rect.height / (this.panel.offsetHeight || 1)) || 1
            const size = (horizontal ? event.clientX - rect.left : event.clientY - rect.top) / scale
            const room = (horizontal ? window.innerWidth * 0.6 : window.innerHeight * 0.7) / scale
            const limit = Math.min(this.max, room)
            this.size = `${Math.round(Math.max(this.min, Math.min(size, limit)))}px`
            document.documentElement.style.setProperty(this.variable, this.size)
          }

          this.onUp = () => {
            document.removeEventListener("pointermove", this.onMove)
            document.removeEventListener("pointerup", this.onUp)
            document.body.style.userSelect = ""
            this.el.removeAttribute("data-dragging")
            if (this.size) { localStorage.setItem(this.storageKey, this.size) }
          }

          this.el.addEventListener("pointerdown", (event) => {
            this.panel = document.getElementById(this.el.dataset.panel)
            if (!this.panel) return
            event.preventDefault()
            this.el.setAttribute("data-dragging", "")
            document.body.style.userSelect = "none"
            document.addEventListener("pointermove", this.onMove)
            document.addEventListener("pointerup", this.onUp)
          })

          this.el.addEventListener("dblclick", () => {
            document.documentElement.style.removeProperty(this.variable)
            localStorage.removeItem(this.storageKey)
            this.size = null
          })
        },

        destroyed() {
          document.removeEventListener("pointermove", this.onMove)
          document.removeEventListener("pointerup", this.onUp)
        }
      }
    </script>
    """
  end

  ## History panel

  attr :groups, :list, required: true
  attr :term, :string, required: true
  attr :count, :integer, required: true
  attr :collapsed, :any, required: true, doc: "MapSet of collapsed group keys"
  attr :active_source, :string, default: nil

  defp history_panel(assigns) do
    ~H"""
    <aside
      id="history-panel"
      class="flex w-[var(--history-width,16rem)] min-w-0 shrink-0 flex-col bg-panel"
    >
      <div class="flex h-9 shrink-0 items-center gap-2 border-b border-line-soft px-2.5">
        <span class="text-[11px] font-semibold uppercase tracking-wide text-muted">History</span>
        <span class="rounded bg-deep px-1.5 py-0.5 font-mono text-[10px] text-faint">{@count}</span>
        <div class="flex-1"></div>
        <button
          type="button"
          phx-click="clear_history"
          data-confirm="Clear the whole request history?"
          title="Clear history"
          class="flex size-6 cursor-pointer items-center justify-center rounded text-faint transition-colors hover:bg-hover hover:text-bad"
        >
          <.icon name="hero-trash" class="size-3.5" />
        </button>
        <button
          type="button"
          phx-click="toggle_sidebar"
          title="Hide history"
          class="flex size-6 cursor-pointer items-center justify-center rounded text-faint transition-colors hover:bg-hover hover:text-ink"
        >
          <.icon name="hero-chevron-double-left" class="size-3.5" />
        </button>
      </div>

      <div class="shrink-0 border-b border-line-soft p-2">
        <form
          id="history-search"
          phx-change="search"
          phx-submit="search"
          class="relative"
          autocomplete="off"
        >
          <.icon
            name="hero-magnifying-glass"
            class="pointer-events-none absolute left-2 top-1/2 size-3.5 -translate-y-1/2 text-faint"
          />
          <input
            type="text"
            name="term"
            value={@term}
            placeholder="Search requests"
            phx-debounce="120"
            class="w-full rounded-md border border-line bg-deep py-1.5 pl-7 pr-7 text-xs text-ink outline-none transition-colors placeholder:text-faint focus:border-accent/60 focus:ring-2 focus:ring-accent/15"
          />
          <button
            :if={@term != ""}
            type="button"
            phx-click="clear_search"
            title="Clear search"
            class="absolute right-1.5 top-1/2 flex size-5 -translate-y-1/2 cursor-pointer items-center justify-center rounded text-faint transition-colors hover:bg-hover hover:text-ink"
          >
            <.icon name="hero-x-mark" class="size-3.5" />
          </button>
        </form>
      </div>

      <div class="min-h-0 flex-1 overflow-y-auto px-1.5 py-2">
        <p :if={@groups == []} class="px-2 py-6 text-center text-xs text-faint">
          <%= if @term == "" do %>
            Nothing here yet — send a request.
          <% else %>
            No request matches “{@term}”.
          <% end %>
        </p>

        <.history_group
          :for={{label, key, entries} <- @groups}
          label={label}
          group={key}
          entries={entries}
          collapsed={MapSet.member?(@collapsed, key)}
          active_source={@active_source}
        />
      </div>
    </aside>
    """
  end

  attr :label, :string, required: true
  attr :group, :string, required: true
  attr :entries, :list, required: true
  attr :collapsed, :boolean, required: true
  attr :active_source, :string, default: nil

  defp history_group(assigns) do
    ~H"""
    <div class="mb-1">
      <button
        type="button"
        id={"group-#{@group}"}
        phx-click="toggle_group"
        phx-value-group={@group}
        aria-expanded={to_string(!@collapsed)}
        class="flex w-full cursor-pointer items-center gap-1 rounded px-1.5 py-1 text-[10px] font-semibold uppercase tracking-wider text-faint transition-colors hover:bg-hover hover:text-muted"
      >
        <.icon
          name="hero-chevron-right"
          class={["size-3 transition-transform", !@collapsed && "rotate-90"]}
        />
        <span class="min-w-0 flex-1 truncate text-left">{@label}</span>
        <span class="font-mono normal-case">{length(@entries)}</span>
      </button>

      <div :if={!@collapsed}>
        <button
          :for={entry <- @entries}
          type="button"
          id={"history-#{entry.id}"}
          phx-click="open_history"
          phx-value-id={entry.id}
          class={[
            "group flex w-full cursor-pointer flex-col gap-0.5 rounded-md px-2 py-1.5 text-left transition-colors",
            if(@active_source == entry.id, do: "bg-active", else: "hover:bg-hover")
          ]}
        >
          <span class="flex w-full items-center gap-2">
            <span class={["shrink-0 font-mono text-[10px] font-semibold", method_color(entry.method)]}>
              {entry.method}
            </span>
            <span class="min-w-0 flex-1 truncate text-xs text-ink">{entry.name}</span>
            <span class="shrink-0 font-mono text-[10px] text-faint">{time(entry.at)}</span>
          </span>
          <span class="flex w-full items-center gap-1.5 font-mono text-[10px] text-muted">
            <span class={status_color(entry.status)}>{entry.status}</span>
            <span class="text-faint">·</span>
            <span>{entry.duration_ms}ms</span>
            <span class="text-faint">·</span>
            <span class="min-w-0 truncate">{path(entry.url)}</span>
          </span>
        </button>
      </div>
    </div>
    """
  end

  ## Request tabs

  attr :tabs, :list, required: true
  attr :active_id, :string, default: nil
  attr :sidebar?, :boolean, required: true

  defp tab_bar(assigns) do
    ~H"""
    <div class="flex h-9 shrink-0 items-stretch border-b border-line-soft bg-panel">
      <button
        :if={!@sidebar?}
        type="button"
        phx-click="toggle_sidebar"
        title="Show history"
        class="flex w-9 shrink-0 cursor-pointer items-center justify-center border-r border-line-soft text-faint transition-colors hover:bg-hover hover:text-ink"
      >
        <.icon name="hero-chevron-double-right" class="size-3.5" />
      </button>

      <div class="flex min-w-0 flex-1 items-stretch overflow-x-auto">
        <div
          :for={tab <- @tabs}
          class={[
            "group flex shrink-0 items-center border-r border-line-soft transition-colors",
            if(tab.id == @active_id, do: "bg-deep", else: "hover:bg-hover")
          ]}
        >
          <button
            type="button"
            phx-click="select_tab"
            phx-value-id={tab.id}
            class="flex cursor-pointer items-center gap-2 py-1 pl-3 pr-1.5"
          >
            <span class={["font-mono text-[10px] font-semibold", method_color(tab.method)]}>
              {tab.method}
            </span>
            <span class={[
              "max-w-36 truncate text-xs",
              if(tab.id == @active_id, do: "text-ink", else: "text-muted")
            ]}>
              {HttpClient.label(tab)}
            </span>
            <.icon
              :if={tab.state == :sending}
              name="hero-arrow-path"
              class="size-3 text-accent motion-safe:animate-spin"
            />
          </button>
          <button
            type="button"
            phx-click="close_tab"
            phx-value-id={tab.id}
            title="Close tab"
            class="mr-1.5 flex size-5 cursor-pointer items-center justify-center rounded text-faint opacity-0 transition-all hover:bg-active hover:text-ink focus:opacity-100 group-hover:opacity-100"
          >
            <.icon name="hero-x-mark" class="size-3" />
          </button>
        </div>
      </div>

      <button
        type="button"
        phx-click="new_tab"
        title="New request"
        class="flex w-9 shrink-0 cursor-pointer items-center justify-center border-l border-line-soft text-muted transition-colors hover:bg-hover hover:text-ink"
      >
        <.icon name="hero-plus" class="size-4" />
      </button>
    </div>
    """
  end

  ## Request editor

  attr :tab, :map, required: true
  attr :form, :map, required: true

  defp request_editor(assigns) do
    ~H"""
    <.form
      for={@form}
      id="request-form"
      phx-change="update"
      phx-submit="send"
      class="flex shrink-0 flex-col"
    >
      <div class="flex items-center gap-2 px-2.5 py-2">
        <div class="relative shrink-0">
          <select
            name={@form[:method].name}
            aria-label="Method"
            class={[
              "cursor-pointer appearance-none rounded-md border border-line bg-panel py-1.5 pl-2.5 pr-7",
              "font-mono text-xs font-semibold outline-none transition-colors hover:border-accent/40 focus:border-accent/60",
              method_color(@tab.method)
            ]}
          >
            <option
              :for={method <- HttpClient.methods()}
              value={method}
              selected={method == @tab.method}
            >
              {method}
            </option>
          </select>
          <.icon
            name="hero-chevron-down"
            class="pointer-events-none absolute right-1.5 top-1/2 size-3.5 -translate-y-1/2 text-faint"
          />
        </div>

        <input
          type="text"
          name={@form[:url].name}
          value={@tab.url}
          id="request-url"
          placeholder="https://api.example.com/v1/users"
          spellcheck="false"
          autocomplete="off"
          phx-debounce="150"
          class="min-w-0 flex-1 rounded-md border border-line bg-deep px-2.5 py-1.5 font-mono text-[13px] text-ink outline-none transition-colors placeholder:text-faint focus:border-accent/60 focus:ring-2 focus:ring-accent/15"
        />

        <%= if @tab.state == :sending do %>
          <.button type="button" phx-click="cancel" variant="secondary" class="shrink-0">
            <.icon name="hero-stop-circle" class="size-4" /> Cancel
          </.button>
        <% else %>
          <.button
            type="submit"
            id="send-request"
            variant="primary"
            class="shrink-0"
            disabled={String.trim(@tab.url) == ""}
            title="Send (Ctrl+Enter)"
          >
            Send <.icon name="hero-paper-airplane" class="size-4" />
          </.button>
        <% end %>
      </div>

      <div class="flex items-stretch gap-1 border-b border-line-soft px-2">
        <.editor_tab
          tab={@tab}
          name="params"
          label="Params"
          count={HttpClient.enabled_count(@tab.params)}
        />
        <.editor_tab
          tab={@tab}
          name="headers"
          label="Headers"
          count={HttpClient.enabled_count(@tab.headers)}
        />
        <.editor_tab tab={@tab} name="auth" label="Auth" />
        <.editor_tab tab={@tab} name="body" label="Body" />

        <div class="flex-1"></div>

        <button
          :if={@tab.editor_tab == "body" and @tab.body_type == "json"}
          type="button"
          phx-click="format_body"
          class="my-1 cursor-pointer rounded px-2 text-[11px] text-muted transition-colors hover:bg-hover hover:text-accent"
        >
          Format JSON
        </button>

        <div class="my-2 mx-1 w-px bg-line-soft"></div>

        <button
          type="button"
          phx-click="open_dialog"
          phx-value-dialog="import_curl"
          title="Create a request from a curl command"
          class="my-1 flex cursor-pointer items-center gap-1 rounded px-1.5 text-[11px] text-muted transition-colors hover:bg-hover hover:text-accent"
        >
          <.icon name="hero-arrow-down-on-square" class="size-3.5" /> Import curl
        </button>
        <button
          type="button"
          phx-click="open_dialog"
          phx-value-dialog="export_curl"
          title="Copy this request as a curl command"
          class="my-1 flex cursor-pointer items-center gap-1 rounded px-1.5 text-[11px] text-muted transition-colors hover:bg-hover hover:text-accent"
        >
          <.icon name="hero-arrow-up-on-square" class="size-3.5" /> Export curl
        </button>
      </div>

      <div id="request-editor" class="h-[var(--request-height,34vh)] min-h-24 overflow-y-auto">
        <%= case @tab.editor_tab do %>
          <% "params" -> %>
            <.row_editor kind="param" rows={@tab.params} placeholder="page" />
          <% "headers" -> %>
            <.row_editor kind="header" rows={@tab.headers} placeholder="Content-Type" />
          <% "auth" -> %>
            <.auth_editor tab={@tab} form={@form} />
          <% "body" -> %>
            <.body_editor tab={@tab} form={@form} />
        <% end %>
      </div>
    </.form>
    """
  end

  attr :tab, :map, required: true
  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :count, :integer, default: 0

  defp editor_tab(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="set_editor_tab"
      phx-value-tab={@name}
      class={[
        "relative flex cursor-pointer items-center gap-1.5 px-2.5 py-2 text-xs transition-colors",
        if(@tab.editor_tab == @name, do: "text-ink", else: "text-muted hover:text-ink")
      ]}
    >
      {@label}
      <span
        :if={@count > 0}
        class="rounded bg-deep px-1 py-0.5 font-mono text-[10px] text-accent"
      >
        {@count}
      </span>
      <span
        :if={@tab.editor_tab == @name}
        class="absolute inset-x-1.5 -bottom-px h-px rounded-full bg-accent"
      />
    </button>
    """
  end

  attr :kind, :string, required: true
  attr :rows, :list, required: true
  attr :placeholder, :string, required: true

  defp row_editor(assigns) do
    ~H"""
    <div class="divide-y divide-line-soft/60">
      <div
        :for={row <- @rows}
        class="group flex items-center gap-2 px-2.5 py-1 transition-colors hover:bg-panel/60"
      >
        <input
          type="checkbox"
          name={"#{@kind}[#{row.id}][enabled]"}
          value="true"
          checked={row.enabled}
          aria-label="Enabled"
          class="size-3.5 shrink-0 cursor-pointer accent-accent"
        />
        <input
          type="text"
          name={"#{@kind}[#{row.id}][key]"}
          value={row.key}
          placeholder={@placeholder}
          spellcheck="false"
          autocomplete="off"
          class={["w-2/5", cell_class()]}
        />
        <input
          type="text"
          name={"#{@kind}[#{row.id}][value]"}
          value={row.value}
          placeholder="value"
          spellcheck="false"
          autocomplete="off"
          class={["min-w-0 flex-1", cell_class()]}
        />
        <button
          type="button"
          phx-click="remove_row"
          phx-value-kind={@kind}
          phx-value-id={row.id}
          title="Remove"
          class="flex size-5 shrink-0 cursor-pointer items-center justify-center rounded text-faint opacity-0 transition-all hover:bg-hover hover:text-bad group-hover:opacity-100"
        >
          <.icon name="hero-x-mark" class="size-3.5" />
        </button>
      </div>

      <button
        type="button"
        phx-click="add_row"
        phx-value-kind={@kind}
        class="flex w-full cursor-pointer items-center gap-1.5 px-2.5 py-1.5 text-[11px] text-muted transition-colors hover:bg-panel/60 hover:text-accent"
      >
        <.icon name="hero-plus" class="size-3.5" /> Add row
      </button>
    </div>
    """
  end

  attr :tab, :map, required: true
  attr :form, :map, required: true

  defp auth_editor(assigns) do
    ~H"""
    <div class="space-y-3 p-2.5">
      <div class="max-w-48">
        <.input
          field={@form[:auth_type]}
          type="select"
          label="Type"
          options={HttpClient.auth_types()}
          value={@tab.auth_type}
        />
      </div>

      <div :if={@tab.auth_type == "bearer"} class="max-w-md">
        <.input
          field={@form[:auth_token]}
          type="text"
          label="Token"
          placeholder="mdt_live_…"
          class={token_class()}
        />
      </div>

      <div :if={@tab.auth_type == "basic"} class="flex max-w-md gap-2">
        <.input field={@form[:auth_username]} type="text" label="Username" class={token_class()} />
        <.input field={@form[:auth_password]} type="password" label="Password" class={token_class()} />
      </div>

      <p :if={@tab.auth_type == "none"} class="text-xs text-faint">
        This request is sent without an authorization header.
      </p>
    </div>
    """
  end

  attr :tab, :map, required: true
  attr :form, :map, required: true

  defp body_editor(assigns) do
    ~H"""
    <div class="flex h-full flex-col">
      <div class="flex items-center gap-2 px-2.5 py-2">
        <span class="text-[11px] uppercase tracking-wide text-muted">Type</span>
        <div class="w-32">
          <.input
            field={@form[:body_type]}
            type="select"
            options={HttpClient.body_types()}
            value={@tab.body_type}
          />
        </div>
      </div>

      <%= if @tab.body_type == "none" do %>
        <p class="px-2.5 text-xs text-faint">This request does not send a body.</p>
      <% else %>
        <textarea
          name={@form[:body].name}
          id="request-body"
          rows="8"
          spellcheck="false"
          placeholder={body_placeholder(@tab.body_type)}
          phx-debounce="200"
          class="min-h-0 flex-1 resize-none border-t border-line-soft bg-deep px-2.5 py-2 font-mono text-xs leading-5 text-ink outline-none placeholder:text-faint focus:ring-1 focus:ring-inset focus:ring-accent/30"
        >{@tab.body}</textarea>
      <% end %>
    </div>
    """
  end

  ## Response

  attr :tab, :map, required: true

  defp response_panel(assigns) do
    ~H"""
    <div class="flex min-h-0 flex-1 flex-col bg-deep">
      <div class="flex h-9 shrink-0 items-center gap-2 border-b border-line-soft bg-panel px-2.5">
        <span class="text-[11px] font-semibold uppercase tracking-wide text-muted">Response</span>

        <%= if @tab.response do %>
          <span class={[
            "rounded border px-1.5 py-0.5 font-mono text-[10px] font-semibold",
            status_pill(@tab.response.status)
          ]}>
            {@tab.response.status} {@tab.response.status_text}
          </span>
          <span class="font-mono text-[10px] text-muted">{@tab.response.duration_ms} ms</span>
          <span class="text-faint">·</span>
          <span class="font-mono text-[10px] text-muted">{@tab.response.size}</span>
        <% end %>

        <div class="flex-1"></div>

        <%= if @tab.response do %>
          <div class="flex items-stretch gap-1">
            <.response_tab tab={@tab} name="body" label="Body" />
            <.response_tab
              tab={@tab}
              name="headers"
              label="Headers"
              count={length(@tab.response.headers)}
            />
          </div>
          <button
            type="button"
            id={"copy-response-#{@tab.id}"}
            phx-hook=".Copy"
            data-copy={@tab.response.body}
            title="Copy response body"
            class="flex cursor-pointer items-center gap-1 rounded px-1.5 py-1 text-[11px] text-muted transition-colors hover:bg-hover hover:text-ink"
          >
            <.icon name="hero-clipboard-document" class="size-3.5" />
            <span data-label>Copy</span>
          </button>
          <script :type={Phoenix.LiveView.ColocatedHook} name=".Copy">
            export default {
              mounted() {
                this.el.addEventListener("click", () => {
                  navigator.clipboard?.writeText(this.el.dataset.copy || "")
                  const label = this.el.querySelector("[data-label]")
                  if (!label) return
                  label.textContent = "Copied"
                  setTimeout(() => label.textContent = "Copy", 1200)
                })
              }
            }
          </script>
        <% end %>
      </div>

      <%= cond do %>
        <% @tab.state == :sending -> %>
          <div class="flex flex-1 flex-col items-center justify-center gap-2 text-xs text-muted">
            <.icon name="hero-arrow-path" class="size-5 text-accent motion-safe:animate-spin" />
            Waiting for response…
          </div>
        <% is_nil(@tab.response) -> %>
          <div class="flex flex-1 flex-col items-center justify-center gap-1.5 text-center">
            <.icon name="hero-paper-airplane" class="size-5 text-faint" />
            <p class="text-xs text-muted">No response yet</p>
            <p class="text-[11px] text-faint">
              Hit Send or press
              <span class="rounded border border-line bg-panel px-1 py-0.5 font-mono">Ctrl</span>
              + <span class="rounded border border-line bg-panel px-1 py-0.5 font-mono">Enter</span>
            </p>
          </div>
        <% @tab.response_tab == "headers" -> %>
          <div class="min-h-0 flex-1 overflow-auto">
            <div
              :for={{name, value} <- @tab.response.headers}
              class="flex gap-3 border-b border-line-soft/60 px-2.5 py-1.5 font-mono text-xs"
            >
              <span class="w-48 shrink-0 text-syn-key">{name}</span>
              <span class="min-w-0 break-all text-ink">{value}</span>
            </div>
          </div>
        <% @tab.response.body == "" -> %>
          <div class="flex flex-1 items-center justify-center text-xs text-faint">
            Empty body ({@tab.response.status} {@tab.response.status_text})
          </div>
        <% true -> %>
          <.code_block
            id={"response-body-#{@tab.id}"}
            content={@tab.response.body}
            language="json"
            class="min-h-0 flex-1"
          />
      <% end %>
    </div>
    """
  end

  attr :tab, :map, required: true
  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :count, :integer, default: 0

  defp response_tab(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="set_response_tab"
      phx-value-tab={@name}
      class={[
        "flex cursor-pointer items-center gap-1 rounded px-1.5 py-1 text-[11px] transition-colors",
        if(@tab.response_tab == @name,
          do: "bg-active text-ink",
          else: "text-muted hover:bg-hover hover:text-ink"
        )
      ]}
    >
      {@label}
      <span :if={@count > 0} class="font-mono text-[10px] text-faint">{@count}</span>
    </button>
    """
  end

  ## Events

  @impl true
  def handle_event("toggle_sidebar", _params, socket) do
    {:noreply, assign(socket, :sidebar?, !socket.assigns.sidebar?)}
  end

  @impl true
  def handle_event("search", %{"term" => term}, socket) do
    {:noreply, socket |> assign(:term, term) |> assign_history()}
  end

  @impl true
  def handle_event("clear_search", _params, socket) do
    {:noreply, socket |> assign(:term, "") |> assign_history()}
  end

  @impl true
  def handle_event("open_dialog", %{"dialog" => dialog}, socket) do
    {:noreply, socket |> assign(:dialog, dialog) |> assign(:import_error, nil)}
  end

  @impl true
  def handle_event("close_dialog", _params, socket) do
    {:noreply, socket |> assign(:dialog, nil) |> assign(:import_error, nil)}
  end

  @impl true
  def handle_event("import_curl", %{"command" => command}, socket) do
    case Curl.from_curl(command) do
      {:ok, attrs} ->
        {:noreply,
         socket
         |> assign(:dialog, nil)
         |> assign(:import_error, nil)
         |> open_tab(HttpClient.new_request(attrs))
         |> put_flash(:info, "Request imported from curl")}

      {:error, reason} ->
        {:noreply, assign(socket, :import_error, String.capitalize(reason))}
    end
  end

  @impl true
  def handle_event("toggle_group", %{"group" => group}, socket) do
    collapsed = socket.assigns.collapsed

    collapsed =
      if MapSet.member?(collapsed, group),
        do: MapSet.delete(collapsed, group),
        else: MapSet.put(collapsed, group)

    {:noreply, assign(socket, :collapsed, collapsed)}
  end

  @impl true
  def handle_event("clear_history", _params, socket) do
    {:noreply, socket |> assign(:history, []) |> assign_history()}
  end

  @impl true
  def handle_event("open_history", %{"id" => id}, socket) do
    entry = Enum.find(socket.assigns.history, &(&1.id == id))
    existing = Enum.find(socket.assigns.tabs, &(&1.source_id == id))

    cond do
      existing -> {:noreply, socket |> assign(:active_id, existing.id) |> sync_tab()}
      entry -> {:noreply, open_tab(socket, HttpClient.request_from_history(entry))}
      true -> {:noreply, socket}
    end
  end

  @impl true
  def handle_event("new_tab", _params, socket) do
    {:noreply, open_tab(socket, HttpClient.new_request())}
  end

  @impl true
  def handle_event("select_tab", %{"id" => id}, socket) do
    {:noreply, socket |> assign(:active_id, id) |> sync_tab()}
  end

  @impl true
  def handle_event("close_tab", %{"id" => id}, socket) do
    index = Enum.find_index(socket.assigns.tabs, &(&1.id == id))
    tabs = Enum.reject(socket.assigns.tabs, &(&1.id == id))

    active_id =
      cond do
        socket.assigns.active_id != id -> socket.assigns.active_id
        tabs == [] -> nil
        true -> Enum.at(tabs, min(index, length(tabs) - 1)).id
      end

    {:noreply, socket |> assign(tabs: tabs, active_id: active_id) |> sync_tab()}
  end

  @impl true
  def handle_event("update", params, socket) do
    {:noreply, update_active(socket, &apply_params(&1, params))}
  end

  @impl true
  def handle_event("set_editor_tab", %{"tab" => tab}, socket) do
    {:noreply, update_active(socket, &%{&1 | editor_tab: tab})}
  end

  @impl true
  def handle_event("set_response_tab", %{"tab" => tab}, socket) do
    {:noreply, update_active(socket, &%{&1 | response_tab: tab})}
  end

  @impl true
  def handle_event("add_row", %{"kind" => kind}, socket) do
    key = rows_key(kind)

    {:noreply,
     update_active(socket, &Map.put(&1, key, Map.fetch!(&1, key) ++ [HttpClient.new_row()]))}
  end

  @impl true
  def handle_event("remove_row", %{"kind" => kind, "id" => id}, socket) do
    key = rows_key(kind)

    {:noreply,
     update_active(socket, fn tab ->
       rows = tab |> Map.fetch!(key) |> Enum.reject(&(&1.id == id)) |> ensure_blank_row()
       Map.put(tab, key, rows)
     end)}
  end

  @impl true
  def handle_event("format_body", _params, socket) do
    case Jason.decode(socket.assigns.tab.body) do
      {:ok, decoded} ->
        {:noreply, update_active(socket, &%{&1 | body: Jason.encode!(decoded, pretty: true)})}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "The body is not valid JSON")}
    end
  end

  @impl true
  def handle_event("send", _params, socket) do
    {:noreply, send_request(socket)}
  end

  @impl true
  def handle_event("maybe_send", params, socket) do
    if params["ctrlKey"] || params["metaKey"] do
      {:noreply, send_request(socket)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("cancel", _params, socket) do
    {:noreply, update_active(socket, &%{&1 | state: :idle, pending: nil})}
  end

  @impl true
  def handle_info({:response, tab_id, ref, response}, socket) do
    case Enum.find(socket.assigns.tabs, &(&1.id == tab_id)) do
      %{pending: ^ref} = tab ->
        entry = HttpClient.history_entry(tab, response)

        socket =
          put_tab(socket, tab_id, fn tab ->
            %{tab | state: :idle, pending: nil, response: response, response_tab: "body"}
          end)

        {:noreply,
         socket
         |> assign(:history, [entry | socket.assigns.history])
         |> assign_history()}

      _stale ->
        {:noreply, socket}
    end
  end

  ## Assign helpers

  defp send_request(socket) do
    tab = socket.assigns.tab

    cond do
      is_nil(tab) ->
        socket

      String.trim(tab.url) == "" ->
        put_flash(socket, :error, "Enter a URL before sending")

      tab.state == :sending ->
        socket

      true ->
        response = HttpClient.perform(tab)
        ref = make_ref()

        schedule_response({:response, tab.id, ref, response}, response.duration_ms)

        put_tab(socket, tab.id, &%{&1 | state: :sending, pending: ref, response: nil})
    end
  end

  # Responses land after the mocked latency, so a request can be seen in flight.
  # Tests turn the wait off to stay deterministic.
  defp schedule_response(message, duration_ms) do
    if Application.get_env(:mdt_client, :simulate_latency, true) do
      Process.send_after(self(), message, min(duration_ms, 900))
    else
      send(self(), message)
    end
  end

  defp open_tab(socket, tab) do
    socket
    |> assign(:tabs, socket.assigns.tabs ++ [tab])
    |> assign(:active_id, tab.id)
    |> sync_tab()
  end

  defp update_active(socket, fun), do: put_tab(socket, socket.assigns.active_id, fun)

  defp put_tab(socket, nil, _fun), do: socket

  defp put_tab(socket, tab_id, fun) do
    tabs =
      Enum.map(socket.assigns.tabs, fn tab -> if tab.id == tab_id, do: fun.(tab), else: tab end)

    socket |> assign(:tabs, tabs) |> sync_tab()
  end

  # `:tab` and `:form` mirror the active tab so templates stay readable.
  defp sync_tab(socket) do
    tab = Enum.find(socket.assigns.tabs, &(&1.id == socket.assigns.active_id))

    assign(socket, tab: tab, form: tab && request_form(tab))
  end

  defp request_form(tab) do
    to_form(
      %{
        "method" => tab.method,
        "url" => tab.url,
        "body" => tab.body,
        "body_type" => tab.body_type,
        "auth_type" => tab.auth_type,
        "auth_token" => tab.auth_token,
        "auth_username" => tab.auth_username,
        "auth_password" => tab.auth_password
      },
      as: :request
    )
  end

  defp assign_history(socket) do
    entries = HttpClient.search_history(socket.assigns.history, socket.assigns.term)

    assign(socket, groups: HttpClient.group_history(entries), count: length(entries))
  end

  @scalar_fields ~w(method url body body_type auth_type auth_token auth_username auth_password)

  defp apply_params(tab, params) do
    scalars = Map.get(params, "request", %{})

    tab =
      Enum.reduce(@scalar_fields, tab, fn field, acc ->
        case Map.fetch(scalars, field) do
          {:ok, value} -> Map.put(acc, String.to_existing_atom(field), value)
          :error -> acc
        end
      end)

    %{
      tab
      | params: merge_rows(tab.params, Map.get(params, "param")),
        headers: merge_rows(tab.headers, Map.get(params, "header"))
    }
  end

  defp merge_rows(rows, nil), do: rows

  defp merge_rows(rows, row_params) do
    rows
    |> Enum.map(fn row ->
      case Map.fetch(row_params, row.id) do
        {:ok, attrs} ->
          %{
            row
            | key: Map.get(attrs, "key", row.key),
              value: Map.get(attrs, "value", row.value),
              enabled: Map.get(attrs, "enabled") == "true"
          }

        :error ->
          row
      end
    end)
    |> ensure_blank_row()
  end

  # Keeps a trailing empty row around, so there is always somewhere to type.
  defp ensure_blank_row(rows) do
    case List.last(rows) do
      nil -> [HttpClient.new_row()]
      %{key: "", value: ""} -> rows
      _filled -> rows ++ [HttpClient.new_row()]
    end
  end

  defp rows_key("param"), do: :params
  defp rows_key("header"), do: :headers

  ## Presentation helpers

  defp method_color("GET"), do: "text-ok"
  defp method_color("POST"), do: "text-warn"
  defp method_color("PUT"), do: "text-accent"
  defp method_color("PATCH"), do: "text-violet"
  defp method_color("DELETE"), do: "text-bad"
  defp method_color(_other), do: "text-teal"

  defp status_color(status) when status < 300, do: "text-ok"
  defp status_color(status) when status < 400, do: "text-accent"
  defp status_color(status) when status < 500, do: "text-warn"
  defp status_color(_status), do: "text-bad"

  defp status_pill(status) when status < 300, do: "border-ok/40 bg-ok-soft/40 text-ok"
  defp status_pill(status) when status < 400, do: "border-accent/40 bg-accent-soft/40 text-accent"
  defp status_pill(status) when status < 500, do: "border-warn/40 bg-warn-soft/40 text-warn"
  defp status_pill(_status), do: "border-bad/40 bg-bad-soft/40 text-bad"

  defp cell_class do
    "rounded border border-transparent bg-transparent px-1.5 py-1 font-mono text-xs text-ink outline-none transition-colors placeholder:text-faint hover:border-line-soft focus:border-accent/50 focus:bg-deep"
  end

  defp token_class do
    "w-full rounded-md border border-line bg-deep px-2.5 py-1.5 font-mono text-xs text-ink outline-none transition-colors placeholder:text-faint focus:border-accent/60"
  end

  defp body_placeholder("json"), do: ~s({\n  "key": "value"\n})
  defp body_placeholder("form"), do: "key=value&other=value"
  defp body_placeholder(_type), do: "Request body"

  defp path(url) do
    uri = URI.parse(url)

    [uri.path || "/", uri.query && "?" <> uri.query]
    |> Enum.reject(&is_nil/1)
    |> Enum.join()
  end

  defp time(at), do: Calendar.strftime(at, "%H:%M")
end
