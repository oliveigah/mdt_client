defmodule MDTClientWeb.HttpClientLive do
  @moduledoc """
  The HTTP client tool: a searchable history on the left, tabbed requests and
  their responses on the right.

  Requests are executed through `MDTClient.HttpClient.Core` and their persisted
  history is read from `MDTClient.HttpClient.Resources`.
  """
  use MDTClientWeb, :live_view

  alias MDTClient.HttpClient.Core
  alias MDTClient.HttpClient.Curl
  alias MDTClient.HttpClient.Resources
  alias MDTClient.HttpClient.Translation
  alias MDTClient.HttpClient.Utils
  alias MDTClient.Tools

  @impl true
  def mount(_params, _session, socket) do
    tabs = [Utils.new_request()]

    {:ok,
     socket
     |> assign(:page_title, "HTTP Client")
     |> assign(:tool, Tools.fetch!(:http))
     |> assign(:username, socket.assigns.current_scope.user.username)
     |> assign(:tabs, tabs)
     |> assign(:active_id, hd(tabs).id)
     |> assign(:sidebar?, true)
     |> assign(:collapsed, MapSet.new())
     |> assign(:selected, MapSet.new())
     |> assign(:dialog, nil)
     |> assign(:dialog_targets, [])
     |> assign(:dialog_value, "")
     |> assign(:dialog_error, nil)
     |> assign(:term, "")
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
          selected={@selected}
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
        :if={@dialog in ~w(export_curl import_curl)}
        dialog={@dialog}
        tab={@tab}
        error={@dialog_error}
      />

      <.metadata_dialog
        :if={@dialog in ~w(add_tag set_description)}
        dialog={@dialog}
        targets={@dialog_targets}
        value={@dialog_value}
        error={@dialog_error}
      />
    </Layouts.app>
    """
  end

  ## Dialogs

  # The shared chrome: a dimmed backdrop, a titled header, and whatever the
  # caller puts in the body.
  attr :id, :string, required: true
  attr :icon, :string, required: true
  attr :title, :string, required: true
  attr :width, :string, default: "max-w-2xl"
  slot :inner_block, required: true

  defp dialog(assigns) do
    ~H"""
    <div
      id={@id}
      class="fixed inset-0 z-40 flex items-center justify-center p-6"
      phx-window-keydown="close_dialog"
      phx-key="Escape"
    >
      <div class="absolute inset-0 bg-black/50" phx-click="close_dialog"></div>

      <div class={[
        "relative flex max-h-full w-full flex-col overflow-hidden rounded-xl border border-line",
        "bg-panel shadow-2xl shadow-black/20 dark:shadow-black/50",
        @width
      ]}>
        <div class="flex h-9 shrink-0 items-center gap-2 border-b border-line-soft px-3">
          <.icon name={@icon} class="size-4 text-accent" />
          <span class="text-xs font-semibold">{@title}</span>
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

        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  attr :dialog, :string, required: true
  attr :tab, :map, default: nil
  attr :error, :string, default: nil

  defp curl_dialog(assigns) do
    ~H"""
    <.dialog
      id="curl-dialog"
      icon="hero-command-line"
      title={if @dialog == "export_curl", do: "Export as curl", else: "Import from curl"}
    >
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
            <p :if={@error} id="curl-import-error" class="flex items-center gap-1.5 text-xs text-bad">
              <.icon name="hero-exclamation-circle" class="size-4" />
              {@error}
            </p>
            <p :if={!@error} class="text-[11px] text-faint">
              The command opens as a new request tab.
            </p>
            <div class="flex-1"></div>
            <.button type="button" phx-click="close_dialog" variant="secondary">Cancel</.button>
            <.button type="submit" variant="primary">Import</.button>
          </div>
        </form>
      <% end %>
    </.dialog>
    """
  end

  # Tags and descriptions for history entries, applied to one entry or to the
  # whole selection.
  attr :dialog, :string, required: true
  attr :targets, :list, required: true
  attr :value, :string, default: ""
  attr :error, :string, default: nil

  defp metadata_dialog(assigns) do
    ~H"""
    <.dialog
      id="metadata-dialog"
      icon={if @dialog == "add_tag", do: "hero-tag", else: "hero-pencil-square"}
      title={if @dialog == "add_tag", do: "Add a tag", else: "Set the description"}
      width="max-w-md"
    >
      <form id="metadata-form" phx-submit="save_metadata" class="flex flex-col">
        <input
          type="text"
          id="metadata-value"
          name="value"
          value={@value}
          spellcheck="false"
          autocomplete="off"
          phx-mounted={JS.focus()}
          placeholder={if @dialog == "add_tag", do: "orders", else: "Create an order"}
          class="bg-deep px-3 py-2.5 font-mono text-xs leading-5 text-ink outline-none placeholder:text-faint focus:ring-1 focus:ring-inset focus:ring-accent/30"
        />

        <div class="flex shrink-0 items-center gap-2 border-t border-line-soft px-3 py-2.5">
          <p :if={@error} id="metadata-error" class="flex items-center gap-1.5 text-xs text-bad">
            <.icon name="hero-exclamation-circle" class="size-4" />
            {@error}
          </p>
          <p :if={!@error} class="text-[11px] text-faint">
            Applies to {requests(length(@targets))}. {if @dialog == "add_tag",
              do: "Tags are searchable.",
              else: "Leave it empty to clear it."}
          </p>
          <div class="flex-1"></div>
          <.button type="button" phx-click="close_dialog" variant="secondary">Cancel</.button>
          <.button type="submit" variant="primary">Save</.button>
        </div>
      </form>
    </.dialog>
    """
  end

  ## History panel

  attr :groups, :list, required: true
  attr :term, :string, required: true
  attr :count, :integer, required: true
  attr :collapsed, :any, required: true, doc: "MapSet of collapsed group keys"
  attr :selected, :any, required: true, doc: "MapSet of selected history entry ids"
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

      <.selection_bar :if={MapSet.size(@selected) > 0} count={MapSet.size(@selected)} />

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
          selected={@selected}
          active_source={@active_source}
        />
      </div>
    </aside>
    """
  end

  # The bulk actions, shown while at least one history entry is selected.
  attr :count, :integer, required: true

  defp selection_bar(assigns) do
    ~H"""
    <div
      id="history-selection"
      class="flex shrink-0 items-center gap-1 border-b border-line-soft bg-accent-soft/50 px-2 py-1.5"
    >
      <span class="min-w-0 truncate text-[11px] text-muted">
        <span class="font-mono text-accent">{@count}</span> selected
      </span>
      <div class="flex-1"></div>
      <button
        type="button"
        phx-click="select_all"
        title="Select every listed request"
        class={selection_action_class()}
      >
        <.icon name="hero-check-circle" class="size-3.5" />
      </button>
      <button
        type="button"
        phx-click="open_metadata"
        phx-value-dialog="add_tag"
        title="Tag the selected requests"
        class={selection_action_class()}
      >
        <.icon name="hero-tag" class="size-3.5" />
      </button>
      <button
        type="button"
        phx-click="open_metadata"
        phx-value-dialog="set_description"
        title="Describe the selected requests"
        class={selection_action_class()}
      >
        <.icon name="hero-pencil-square" class="size-3.5" />
      </button>
      <button
        type="button"
        phx-click="delete_entries"
        data-confirm="Delete the selected requests?"
        title="Delete the selected requests"
        class={[selection_action_class(), "hover:text-bad"]}
      >
        <.icon name="hero-trash" class="size-3.5" />
      </button>
      <button
        type="button"
        phx-click="clear_selection"
        title="Clear the selection"
        class={selection_action_class()}
      >
        <.icon name="hero-x-mark" class="size-3.5" />
      </button>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :group, :string, required: true
  attr :entries, :list, required: true
  attr :collapsed, :boolean, required: true
  attr :selected, :any, required: true
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
        <.history_entry
          :for={entry <- @entries}
          entry={entry}
          selected={MapSet.member?(@selected, entry.id)}
          active={@active_source == entry.id}
        />
      </div>
    </div>
    """
  end

  attr :entry, :map, required: true
  attr :selected, :boolean, required: true
  attr :active, :boolean, required: true

  defp history_entry(assigns) do
    ~H"""
    <div class={[
      "group relative flex items-start gap-1.5 rounded-md pl-1.5 pr-2 transition-colors",
      if(@active, do: "bg-active", else: "hover:bg-hover")
    ]}>
      <button
        type="button"
        id={"select-history-#{@entry.id}"}
        phx-click="toggle_select"
        phx-value-id={@entry.id}
        role="checkbox"
        aria-checked={to_string(@selected)}
        title="Select this request"
        class={[
          "mt-2 flex size-3.5 shrink-0 cursor-pointer items-center justify-center rounded-sm border transition-all",
          if(@selected,
            do: "border-accent bg-accent text-deep",
            else:
              "border-line text-transparent opacity-0 hover:border-accent focus:opacity-100 group-hover:opacity-100"
          )
        ]}
      >
        <.icon name="hero-check" class="size-2.5" />
      </button>

      <button
        type="button"
        id={"history-#{@entry.id}"}
        phx-click="open_history"
        phx-value-id={@entry.id}
        class="flex min-w-0 flex-1 cursor-pointer flex-col gap-0.5 py-1.5 text-left"
      >
        <span class="flex w-full items-center gap-2">
          <span class={[
            "shrink-0 font-mono text-[10px] font-semibold",
            method_color(@entry.method)
          ]}>
            {@entry.method}
          </span>
          <span class="min-w-0 flex-1 truncate text-xs text-ink">{@entry.name}</span>
          <span class="shrink-0 font-mono text-[10px] text-faint">{time(@entry.at)}</span>
        </span>
        <span
          :if={host(@entry.url) != ""}
          class="w-full truncate font-mono text-[10px] text-faint"
        >
          {host(@entry.url)}
        </span>
        <span class="flex w-full items-center gap-1.5 font-mono text-[10px] text-muted">
          <span class={status_color(@entry.status)}>{@entry.status}</span>
          <span class="text-faint">·</span>
          <span>{@entry.duration_ms}ms</span>
          <span class="text-faint">·</span>
          <span class="min-w-0 truncate">{path(@entry.url)}</span>
        </span>
        <span :if={@entry.tags != []} class="flex w-full flex-wrap items-center gap-1 pt-0.5">
          <span
            :for={tag <- @entry.tags}
            class="rounded bg-accent-soft px-1 py-px font-mono text-[9px] leading-4 text-accent"
          >
            {tag}
          </span>
        </span>
      </button>

      <div class={[
        "absolute right-1 top-1 hidden items-center gap-0.5 rounded group-hover:flex",
        if(@active, do: "bg-active", else: "bg-hover")
      ]}>
        <button
          type="button"
          phx-click="open_metadata"
          phx-value-dialog="add_tag"
          phx-value-id={@entry.id}
          title="Add a tag"
          class={entry_action_class()}
        >
          <.icon name="hero-tag" class="size-3" />
        </button>
        <button
          type="button"
          phx-click="open_metadata"
          phx-value-dialog="set_description"
          phx-value-id={@entry.id}
          title="Set the description"
          class={entry_action_class()}
        >
          <.icon name="hero-pencil-square" class="size-3" />
        </button>
        <button
          type="button"
          phx-click="delete_entries"
          phx-value-id={@entry.id}
          data-confirm="Delete this request?"
          title="Delete this request"
          class={[entry_action_class(), "hover:text-bad"]}
        >
          <.icon name="hero-trash" class="size-3" />
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

      <.tab_strip id="request-tabs" class="flex min-w-0 flex-1 items-stretch overflow-x-auto">
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
              {Utils.label(tab)}
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
      </.tab_strip>

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
    <div class="flex shrink-0 flex-col">
      <.request_meta tab={@tab} />

      <.form for={@form} id="request-form" phx-change="update" phx-submit="send" class="flex flex-col">
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
                :for={method <- Utils.methods()}
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
            count={Utils.enabled_count(@tab.params)}
          />
          <.editor_tab
            tab={@tab}
            name="headers"
            label="Headers"
            count={Utils.enabled_count(@tab.headers)}
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
    </div>
    """
  end

  # The description and tags carried into history when the request is sent.
  # They live outside `#request-form` so that Enter adds a tag instead of
  # firing the request.
  attr :tab, :map, required: true

  defp request_meta(assigns) do
    ~H"""
    <div class="flex flex-wrap items-center gap-x-3 gap-y-1 border-b border-line-soft px-2.5 py-1.5">
      <form
        id="request-description"
        phx-change="update_meta"
        phx-submit="update_meta"
        class="flex min-w-40 flex-1 items-center gap-1.5"
      >
        <.icon name="hero-pencil-square" class="size-3.5 shrink-0 text-faint" />
        <input
          type="text"
          id="request-description-input"
          name="description"
          value={@tab.name}
          placeholder="Describe this request"
          autocomplete="off"
          class={["min-w-0 flex-1", meta_input_class()]}
        />
      </form>

      <div class="flex flex-wrap items-center gap-1">
        <span
          :for={tag <- @tab.tags}
          class="flex items-center gap-1 rounded bg-accent-soft px-1.5 py-0.5 font-mono text-[10px] text-accent"
        >
          {tag}
          <button
            type="button"
            phx-click="remove_tag"
            phx-value-tag={tag}
            title={"Remove #{tag}"}
            class="flex cursor-pointer items-center text-accent/60 transition-colors hover:text-bad"
          >
            <.icon name="hero-x-mark" class="size-3" />
          </button>
        </span>

        <form
          id="request-tag"
          phx-change="update_tag_draft"
          phx-submit="add_tag"
          class="flex shrink-0 items-center gap-1.5"
        >
          <.icon name="hero-tag" class="size-3.5 shrink-0 text-faint" />
          <input
            type="text"
            id="request-tag-input"
            name="tag"
            value={@tab.tag_draft}
            placeholder="Add tag"
            autocomplete="off"
            class={["w-28 shrink-0 font-mono focus:w-40", meta_input_class()]}
          />
        </form>
      </div>
    </div>
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
          options={Utils.auth_types()}
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
            options={Utils.body_types()}
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
    {:noreply, socket |> close_dialog() |> assign(:dialog, dialog)}
  end

  @impl true
  def handle_event("close_dialog", _params, socket) do
    {:noreply, close_dialog(socket)}
  end

  @impl true
  def handle_event("import_curl", %{"command" => command}, socket) do
    case Curl.from_curl(command) do
      {:ok, attrs} ->
        {:noreply,
         socket
         |> close_dialog()
         |> open_tab(Utils.new_request(attrs))
         |> put_flash(:info, "Request imported from curl")}

      {:error, reason} ->
        {:noreply, assign(socket, :dialog_error, String.capitalize(reason))}
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
    :ok = Resources.clear(socket.assigns.username)
    {:noreply, socket |> assign(:selected, MapSet.new()) |> assign_history()}
  end

  @impl true
  def handle_event("toggle_select", %{"id" => id}, socket) do
    selected = socket.assigns.selected

    selected =
      if MapSet.member?(selected, id),
        do: MapSet.delete(selected, id),
        else: MapSet.put(selected, id)

    {:noreply, assign(socket, :selected, selected)}
  end

  @impl true
  def handle_event("select_all", _params, socket) do
    ids = for {_label, _key, entries} <- socket.assigns.groups, entry <- entries, do: entry.id

    {:noreply, assign(socket, :selected, MapSet.new(ids))}
  end

  @impl true
  def handle_event("clear_selection", _params, socket) do
    {:noreply, assign(socket, :selected, MapSet.new())}
  end

  # Without an id these work on the whole selection.
  @impl true
  def handle_event("open_metadata", %{"dialog" => dialog} = params, socket) do
    case targets(socket, params) do
      [] ->
        {:noreply, socket}

      targets ->
        {:noreply,
         socket
         |> close_dialog()
         |> assign(:dialog, dialog)
         |> assign(:dialog_targets, targets)
         |> assign(:dialog_value, metadata_value(socket, dialog, targets))}
    end
  end

  @impl true
  def handle_event("delete_entries", params, socket) do
    case targets(socket, params) do
      [] ->
        {:noreply, socket}

      targets ->
        {:noreply,
         socket
         |> apply_to_entries(targets, &Core.delete(socket.assigns.username, &1), "Deleted")
         |> update(:selected, &MapSet.difference(&1, MapSet.new(targets)))}
    end
  end

  @impl true
  def handle_event("save_metadata", %{"value" => value}, socket) do
    %{dialog: dialog, dialog_targets: targets, username: username} = socket.assigns

    case {dialog, String.trim(value)} do
      {"add_tag", ""} ->
        {:noreply, assign(socket, :dialog_error, "Enter a tag")}

      {"add_tag", tag} ->
        {:noreply,
         socket
         |> close_dialog()
         |> apply_to_entries(targets, &Core.add_tag(username, &1, tag), "Tagged")}

      {"set_description", description} ->
        description = if description == "", do: nil, else: description

        {:noreply,
         socket
         |> close_dialog()
         |> apply_to_entries(
           targets,
           &Core.set_description(username, &1, description),
           "Described"
         )}
    end
  end

  @impl true
  def handle_event("open_history", %{"id" => id}, socket) do
    existing = Enum.find(socket.assigns.tabs, &(&1.source_id == id))

    cond do
      existing ->
        {:noreply, socket |> assign(:active_id, existing.id) |> sync_tab()}

      true ->
        case Integer.parse(id) do
          {identifier, ""} ->
            case Resources.get(socket.assigns.username, identifier) do
              {:ok, entry} ->
                {:noreply, open_tab(socket, Translation.request_from_history(entry))}

              :error ->
                {:noreply,
                 socket |> assign_history() |> put_flash(:error, "History entry not found")}
            end

          :error ->
            {:noreply, socket}
        end
    end
  end

  @impl true
  def handle_event("new_tab", _params, socket) do
    {:noreply, open_tab(socket, Utils.new_request())}
  end

  @impl true
  def handle_event("select_tab", %{"id" => id}, socket) do
    {:noreply, socket |> assign(:active_id, id) |> sync_tab()}
  end

  @impl true
  def handle_event("reorder_tabs", %{"order" => order}, socket) when is_list(order) do
    {:noreply, assign(socket, :tabs, MDTClientWeb.Tabs.reorder(socket.assigns.tabs, order))}
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
  def handle_event("update_meta", %{"description" => description}, socket) do
    {:noreply, update_active(socket, &%{&1 | name: description})}
  end

  @impl true
  def handle_event("update_tag_draft", %{"tag" => tag}, socket) do
    {:noreply, update_active(socket, &%{&1 | tag_draft: tag})}
  end

  @impl true
  def handle_event("add_tag", %{"tag" => tag}, socket) do
    {:noreply, update_active(socket, &commit_tag_draft(%{&1 | tag_draft: tag}))}
  end

  @impl true
  def handle_event("remove_tag", %{"tag" => tag}, socket) do
    {:noreply, update_active(socket, &%{&1 | tags: List.delete(&1.tags, tag)})}
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

    {:noreply, update_active(socket, &Map.put(&1, key, Map.fetch!(&1, key) ++ [Utils.new_row()]))}
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
    case socket.assigns.tab do
      %{pending: pending} when not is_nil(pending) ->
        {:noreply,
         socket
         |> cancel_async(pending)
         |> update_active(&%{&1 | state: :idle, pending: nil})}

      _tab ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_async({:request, tab_id} = task, {:ok, {result, duration_ms}}, socket) do
    case Enum.find(socket.assigns.tabs, &(&1.id == tab_id)) do
      %{pending: ^task} ->
        socket =
          put_tab(socket, tab_id, fn tab ->
            %{
              tab
              | state: :idle,
                pending: nil,
                response: Translation.response_view(result, duration_ms),
                response_tab: "body"
            }
          end)

        {:noreply, assign_history(socket)}

      _stale ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_async({:request, tab_id} = task, {:exit, reason}, socket) do
    case Enum.find(socket.assigns.tabs, &(&1.id == tab_id)) do
      %{pending: ^task} ->
        socket =
          put_tab(socket, tab_id, fn tab ->
            %{
              tab
              | state: :idle,
                pending: nil,
                response:
                  Translation.response_view({:error, RuntimeError.exception(inspect(reason))}, 0),
                response_tab: "body"
            }
          end)

        {:noreply, socket}

      _stale ->
        {:noreply, socket}
    end
  end

  ## Assign helpers

  defp send_request(socket) do
    # A tag typed but never submitted would otherwise be dropped on send.
    socket = update_active(socket, &commit_tag_draft/1)
    tab = socket.assigns.tab

    cond do
      is_nil(tab) ->
        socket

      String.trim(tab.url) == "" ->
        put_flash(socket, :error, "Enter a URL before sending")

      tab.state == :sending ->
        socket

      true ->
        request = Translation.to_req(tab)
        metadata = %{description: tab.name, tags: tab.tags}
        username = socket.assigns.username
        task = {:request, tab.id}

        socket
        |> put_tab(tab.id, &%{&1 | state: :sending, pending: task, response: nil})
        |> start_async(task, fn ->
          started_at = System.monotonic_time()
          result = Core.request(username, request, metadata)

          duration_ms =
            (System.monotonic_time() - started_at)
            |> System.convert_time_unit(:native, :millisecond)

          {result, duration_ms}
        end)
    end
  end

  defp commit_tag_draft(%{tag_draft: draft} = tab) do
    case String.trim(draft) do
      "" -> %{tab | tag_draft: ""}
      tag -> %{tab | tags: Enum.uniq(tab.tags ++ [tag]), tag_draft: ""}
    end
  end

  defp close_dialog(socket) do
    assign(socket, dialog: nil, dialog_targets: [], dialog_value: "", dialog_error: nil)
  end

  # Prefills the dialog with the description already on a single entry; a
  # selection has no single value to show.
  defp metadata_value(socket, "set_description", [id]) do
    socket.assigns.groups
    |> Enum.flat_map(fn {_label, _key, entries} -> entries end)
    |> Enum.find_value("", &(&1.id == id && (&1.description || "")))
  end

  defp metadata_value(_socket, _dialog, _targets), do: ""

  # The entry under the cursor, or the whole selection when there is no id.
  defp targets(_socket, %{"id" => id}), do: [id]
  defp targets(socket, _params), do: MapSet.to_list(socket.assigns.selected)

  defp apply_to_entries(socket, targets, update, verb) do
    {updated, failed} =
      Enum.reduce(targets, {0, 0}, fn id, {updated, failed} ->
        case update.(id) do
          {:ok, _entry} -> {updated + 1, failed}
          {:error, _reason} -> {updated, failed + 1}
        end
      end)

    socket
    |> assign_history()
    |> flash_entries(verb, updated, failed)
  end

  defp flash_entries(socket, _verb, 0, failed),
    do: put_flash(socket, :error, "Could not update #{requests(failed)}")

  defp flash_entries(socket, verb, updated, 0),
    do: put_flash(socket, :info, "#{verb} #{requests(updated)}")

  defp flash_entries(socket, verb, updated, failed) do
    put_flash(socket, :info, "#{verb} #{requests(updated)}, #{failed} could not be updated")
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
    entries =
      socket.assigns.username
      |> Resources.search(socket.assigns.term)
      |> Enum.map(&Translation.history_entry/1)

    assign(socket, groups: Utils.group_history(entries), count: length(entries))
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
      nil -> [Utils.new_row()]
      %{key: "", value: ""} -> rows
      _filled -> rows ++ [Utils.new_row()]
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

  defp requests(1), do: "1 request"
  defp requests(count), do: "#{count} requests"

  defp selection_action_class do
    "flex size-6 shrink-0 cursor-pointer items-center justify-center rounded text-muted transition-colors hover:bg-hover hover:text-ink"
  end

  defp entry_action_class do
    "flex size-5 cursor-pointer items-center justify-center rounded text-faint transition-colors hover:bg-panel hover:text-accent"
  end

  defp meta_input_class do
    "rounded border border-transparent bg-transparent px-1.5 py-0.5 text-xs text-ink outline-none transition-all placeholder:text-faint hover:border-line-soft focus:border-accent/50 focus:bg-deep"
  end

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

  # The authority the request went to, with the port only when it is not the
  # default one for the scheme.
  defp host(url) do
    case URI.parse(url) do
      %URI{host: nil} -> ""
      %URI{host: host} = uri -> host <> port(uri)
    end
  end

  defp port(%URI{scheme: "https", port: 443}), do: ""
  defp port(%URI{scheme: "http", port: 80}), do: ""
  defp port(%URI{port: nil}), do: ""
  defp port(%URI{port: port}), do: ":#{port}"

  defp time(at), do: Calendar.strftime(at, "%H:%M")
end
