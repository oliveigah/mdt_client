defmodule MDTClientWeb.DiagramsLive do
  @moduledoc """
  The diagrams tool: every diagram kept, and searchable, on the left, and the
  canvas of the one open on the right.

  The canvas is the `DiagramEditor` hook, `assets/js/diagram_editor.js`. It
  draws and edits in the browser and sends each finished change back as the
  "save" event, to be kept in `MDTClient.Diagrams.Library`. This LiveView
  decides which diagram is open, and keeps the list, the title and the search.

  A diagram never saved is a draft: it has an identifier, but no place in the
  library until something is drawn in it or it is given a name.
  """
  use MDTClientWeb, :live_view

  alias MDTClient.Diagrams.Diagram
  alias MDTClient.Diagrams.Library
  alias MDTClient.HttpClient.Utils
  alias MDTClient.Tools

  @colors [
    {"ink", "Ink", "bg-ink"},
    {"accent", "Blue", "bg-accent"},
    {"ok", "Green", "bg-ok"},
    {"warn", "Amber", "bg-warn"},
    {"bad", "Red", "bg-bad"},
    {"violet", "Violet", "bg-violet"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    username = socket.assigns.current_scope.user.username

    if connected?(socket), do: Library.subscribe(username)

    current =
      case Library.latest(username) do
        {:ok, diagram} -> current(diagram)
        :error -> current(Diagram.new(), false)
      end

    {:ok,
     socket
     |> assign(:page_title, "Diagrams")
     |> assign(:tool, Tools.fetch!(:diagrams))
     |> assign(:username, username)
     |> assign(:current, current)
     |> assign(:sidebar?, true)
     |> assign(:collapsed, MapSet.new())
     |> assign(:menu, nil)
     |> assign(:term, "")
     |> assign_list()}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    case Library.get(socket.assigns.username, id) do
      {:ok, diagram} -> {:noreply, open(socket, current(diagram), diagram.elements)}
      :error -> {:noreply, put_flash(socket, :error, "Diagram not found")}
    end
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      tool={@tool}
      notices={@notices}
      update={@update}
    >
      <div class="flex min-h-0 flex-1 overflow-hidden">
        <.diagram_list
          :if={@sidebar?}
          groups={@groups}
          term={@term}
          count={@count}
          collapsed={@collapsed}
          current_id={@current.id}
        />

        <.resizer
          :if={@sidebar?}
          id="diagram-list-resizer"
          panel="diagram-list-panel"
          variable="--diagram-list-width"
          storage_key="mdt:diagram-list-width"
          axis="x"
          min="180"
          max="520"
        />

        <section class="flex min-w-0 flex-1 flex-col bg-app">
          <.workspace_bar current={@current} sidebar?={@sidebar?} />
          <.canvas />
        </section>
      </div>

      <.diagram_menu :if={@menu} menu={@menu} />
    </Layouts.app>
    """
  end

  ## Diagram list

  attr :groups, :list, required: true
  attr :term, :string, required: true
  attr :count, :integer, required: true
  attr :collapsed, :any, required: true, doc: "MapSet of collapsed group keys"
  attr :current_id, :string, required: true

  defp diagram_list(assigns) do
    ~H"""
    <aside
      id="diagram-list-panel"
      class="flex w-[var(--diagram-list-width,16rem)] min-w-0 shrink-0 flex-col bg-panel"
    >
      <div class="flex h-9 shrink-0 items-center gap-2 border-b border-line-soft px-2.5">
        <span class="text-[11px] font-semibold uppercase tracking-wide text-muted">Diagrams</span>
        <span class="rounded bg-deep px-1.5 py-0.5 font-mono text-[10px] text-faint">{@count}</span>
        <div class="flex-1"></div>
        <button
          type="button"
          id="new-diagram"
          phx-click="new_diagram"
          title="New diagram"
          class="flex size-6 cursor-pointer items-center justify-center rounded text-faint transition-colors hover:bg-hover hover:text-accent"
        >
          <.icon name="hero-plus" class="size-3.5" />
        </button>
        <button
          type="button"
          phx-click="toggle_sidebar"
          title="Hide diagrams"
          class="flex size-6 cursor-pointer items-center justify-center rounded text-faint transition-colors hover:bg-hover hover:text-ink"
        >
          <.icon name="hero-chevron-double-left" class="size-3.5" />
        </button>
      </div>

      <div class="shrink-0 border-b border-line-soft p-2">
        <form
          id="diagram-search"
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
            placeholder="Search every word drawn"
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

      <%!-- A click opens a diagram, and a right click offers what else can be
            done with it. --%>
      <div
        id="diagram-list"
        phx-hook="MDTClientWeb.PanelComponents.RowMenu"
        role="listbox"
        aria-label="Diagrams"
        class="min-h-0 flex-1 overflow-y-auto px-1.5 py-2"
      >
        <p :if={@groups == []} class="px-2 py-6 text-center text-xs text-faint">
          <%= if @term == "" do %>
            Nothing here yet — draw something.
          <% else %>
            No diagram mentions “{@term}”.
          <% end %>
        </p>

        <div :for={{label, key, entries} <- @groups} class="mb-1">
          <button
            type="button"
            id={"diagram-group-#{key}"}
            phx-click="toggle_group"
            phx-value-group={key}
            aria-expanded={to_string(!MapSet.member?(@collapsed, key))}
            class="flex w-full cursor-pointer items-center gap-1 rounded px-1.5 py-1 text-[10px] font-semibold uppercase tracking-wider text-faint transition-colors hover:bg-hover hover:text-muted"
          >
            <.icon
              name="hero-chevron-right"
              class={["size-3 transition-transform", !MapSet.member?(@collapsed, key) && "rotate-90"]}
            />
            <span class="min-w-0 flex-1 truncate text-left">{label}</span>
            <span class="font-mono normal-case">{length(entries)}</span>
          </button>

          <div :if={!MapSet.member?(@collapsed, key)} role="group" aria-label={label}>
            <.diagram_entry
              :for={entry <- entries}
              entry={entry}
              active={entry.id == @current_id}
            />
          </div>
        </div>
      </div>
    </aside>
    """
  end

  attr :entry, :map, required: true
  attr :active, :boolean, required: true

  defp diagram_entry(assigns) do
    ~H"""
    <div
      id={"diagram-row-#{@entry.id}"}
      data-menu-kind="diagram"
      data-menu-id={@entry.id}
      class={[
        "group relative flex select-none items-start rounded-md px-2 transition-colors",
        if(@active,
          do: "bg-active shadow-[inset_2px_0_0_0_var(--color-accent)]",
          else: "hover:bg-hover"
        )
      ]}
    >
      <button
        type="button"
        id={"diagram-#{@entry.id}"}
        phx-click="open_diagram"
        phx-value-id={@entry.id}
        role="option"
        aria-selected={to_string(@active)}
        class="flex min-w-0 flex-1 cursor-pointer flex-col gap-0.5 py-1.5 text-left focus-visible:outline-2 focus-visible:-outline-offset-2 focus-visible:outline-accent"
      >
        <span class="flex w-full items-center gap-2">
          <.icon
            name="diagram"
            class={["size-3.5 shrink-0", if(@active, do: "text-accent", else: "text-faint")]}
          />
          <span class="min-w-0 flex-1 truncate text-xs text-ink">{@entry.title}</span>
          <span class="shrink-0 font-mono text-[10px] text-faint">{time(@entry.at)}</span>
        </span>
        <%= if @entry.snippet do %>
          <.snippet parts={@entry.snippet} />
        <% else %>
          <span class="w-full truncate pl-5.5 font-mono text-[10px] text-faint">
            {elements(@entry.count)}
          </span>
        <% end %>
      </button>

      <div class={[
        "absolute right-1 top-1 hidden items-center gap-0.5 rounded group-hover:flex",
        if(@active, do: "bg-active", else: "bg-hover")
      ]}>
        <button
          type="button"
          phx-click="duplicate_diagram"
          phx-value-id={@entry.id}
          title="Duplicate this diagram"
          class={entry_action_class()}
        >
          <.icon name="hero-document-duplicate" class="size-3" />
        </button>
        <button
          type="button"
          phx-click="delete_diagram"
          phx-value-id={@entry.id}
          data-confirm="Delete this diagram?"
          title="Delete this diagram"
          class={[entry_action_class(), "hover:text-bad"]}
        >
          <.icon name="hero-trash" class="size-3" />
        </button>
      </div>
    </div>
    """
  end

  # The words around a search match, the match itself marked.
  attr :parts, :any, required: true, doc: "`{before, match, after}`"

  defp snippet(%{parts: {before, match, rest}} = assigns) do
    assigns = assign(assigns, before: before, match: match, rest: rest)

    ~H"""
    <span class="w-full truncate pl-5.5 text-[11px] text-muted">
      {@before}<mark class="rounded-sm bg-warn-soft px-0.5 text-warn-strong">{@match}</mark>{@rest}
    </span>
    """
  end

  attr :menu, :map, required: true

  defp diagram_menu(assigns) do
    ~H"""
    <.context_menu
      id="diagram-menu"
      anchor={@menu.anchor || "diagram-row-#{@menu.id}"}
      at={@menu.at}
      label="Diagram actions"
    >
      <.menu_item
        id="diagram-menu-open"
        icon="hero-arrow-top-right-on-square"
        phx-click="open_diagram"
        phx-value-id={@menu.id}
      >
        Open diagram
      </.menu_item>
      <.menu_item
        id="diagram-menu-duplicate"
        icon="hero-document-duplicate"
        phx-click="duplicate_diagram"
        phx-value-id={@menu.id}
      >
        Duplicate
      </.menu_item>

      <.menu_separator />

      <.menu_item
        id="diagram-menu-delete"
        icon="hero-trash"
        danger
        phx-click="delete_diagram"
        phx-value-id={@menu.id}
        data-confirm="Delete this diagram?"
      >
        Delete…
      </.menu_item>
    </.context_menu>
    """
  end

  ## Workspace

  attr :current, :map, required: true
  attr :sidebar?, :boolean, required: true

  defp workspace_bar(assigns) do
    assigns = assign(assigns, :default_title, Diagram.default_title())

    ~H"""
    <div class="flex h-9 shrink-0 items-stretch border-b border-line-soft bg-panel">
      <button
        :if={!@sidebar?}
        type="button"
        id="show-diagram-list"
        phx-click="toggle_sidebar"
        title="Show diagrams"
        class="flex w-9 shrink-0 cursor-pointer items-center justify-center border-r border-line-soft text-faint transition-colors hover:bg-hover hover:text-ink"
      >
        <.icon name="hero-chevron-double-right" class="size-3.5" />
      </button>

      <form
        id="diagram-title-form"
        phx-change="rename"
        phx-submit={JS.push("rename") |> JS.focus(to: "#diagram-canvas")}
        class="flex min-w-0 flex-1 items-center gap-1.5 pl-3"
        autocomplete="off"
      >
        <.icon name="diagram" class="size-4 shrink-0 text-accent" />
        <input
          type="text"
          id="diagram-title"
          name="title"
          value={if @current.title == @default_title, do: "", else: @current.title}
          placeholder={@default_title}
          phx-debounce="300"
          maxlength="200"
          spellcheck="false"
          aria-label="Diagram title"
          class="min-w-0 max-w-md flex-1 rounded border border-transparent bg-transparent px-1.5 py-0.5 text-[13px] font-medium text-ink outline-none transition-colors placeholder:text-faint hover:border-line-soft focus:border-accent/50 focus:bg-deep"
        />
      </form>

      <span
        id="diagram-status"
        class="flex shrink-0 items-center gap-1.5 px-3 text-[11px] text-faint"
      >
        <%= if @current.saved? do %>
          <.icon name="hero-check-circle" class="size-3.5 text-ok" />
          Saved {time(local(@current.updated_at))}
        <% else %>
          <.icon name="hero-pencil" class="size-3.5" /> Draft · kept once you draw
        <% end %>
      </span>
    </div>
    """
  end

  # Rendered once: from then on the hook owns everything in here, which is
  # why the chrome carries data attributes rather than LiveView bindings.
  defp canvas(assigns) do
    assigns = assign(assigns, :colors, @colors)

    ~H"""
    <div
      id="diagram-canvas"
      phx-hook="DiagramEditor"
      phx-update="ignore"
      tabindex="0"
      aria-label="Diagram canvas"
      class="relative min-h-0 flex-1 select-none overflow-hidden bg-deep outline-none"
    >
      <div
        data-role="grid"
        class="pointer-events-none absolute inset-0 bg-[image:radial-gradient(circle,var(--color-line)_1px,transparent_1.5px)] bg-[length:24px_24px] transition-opacity"
      >
      </div>

      <%!-- The hook finds what is under the pointer itself, so every press
            lands on the svg. A press on a drawn node replaced as the press
            redraws it would land nowhere and take focus off the canvas. --%>
      <svg id="diagram-svg" data-role="svg" class="absolute inset-0 size-full touch-none">
        <g data-role="viewport" class="pointer-events-none">
          <g data-role="scene"></g>
          <g data-role="overlay"></g>
          <g data-role="ports"></g>
        </g>
      </svg>

      <textarea
        id="diagram-text-editor"
        data-role="text-editor"
        hidden
        rows="1"
        spellcheck="false"
        aria-label="Text"
        class="absolute z-20 m-0 select-text resize-none overflow-hidden border-0 bg-transparent p-0 caret-accent outline-none placeholder:text-faint"
      ></textarea>

      <div
        data-role="empty-hint"
        class="pointer-events-none absolute inset-0 flex items-center justify-center"
      >
        <div class="flex flex-col items-center gap-3 text-center">
          <span class="flex size-11 items-center justify-center rounded-xl border border-line bg-panel text-accent shadow-sm">
            <.icon name="diagram" class="size-5" />
          </span>
          <div>
            <p class="text-sm text-ink">A blank canvas</p>
            <p class="mt-0.5 text-xs text-muted">
              Pick a shape or a table above, or double click anywhere to write.
            </p>
          </div>
        </div>
      </div>

      <div class="pointer-events-none absolute inset-x-0 top-3 z-10 flex justify-center">
        <div
          id="diagram-toolbar"
          role="toolbar"
          aria-label="Drawing tools"
          class={[floating_class(), "pointer-events-auto flex items-center gap-0.5 p-1"]}
        >
          <.tool_button tool="hand" label="Pan" key="H">
            <.icon name="hero-hand-raised" class="size-4" />
          </.tool_button>
          <span class="mx-0.5 h-5 w-px bg-line-soft"></span>
          <.tool_button tool="select" label="Select" key="V" number="1">
            <.glyph name="select" />
          </.tool_button>
          <.tool_button tool="rectangle" label="Rectangle" key="R" number="2">
            <.glyph name="rectangle" />
          </.tool_button>
          <.tool_button tool="diamond" label="Diamond" key="D" number="3">
            <.glyph name="diamond" />
          </.tool_button>
          <.tool_button tool="ellipse" label="Ellipse" key="O" number="4">
            <.glyph name="ellipse" />
          </.tool_button>
          <.tool_button tool="arrow" label="Arrow" key="A" number="5">
            <.glyph name="arrow" />
          </.tool_button>
          <.tool_button tool="text" label="Text" key="T" number="6">
            <.glyph name="text" />
          </.tool_button>
          <.tool_button tool="table" label="Table" number="7">
            <.glyph name="table" />
          </.tool_button>
        </div>
      </div>

      <div
        id="diagram-style"
        data-role="style-panel"
        hidden
        class={[floating_class(), "absolute right-3 top-3 z-10 w-52 space-y-2.5 p-2.5"]}
      >
        <.style_row label="Color" row="color">
          <div class="flex flex-wrap gap-1.5">
            <button
              :for={{color, name, swatch} <- @colors}
              type="button"
              data-style="color"
              data-value={color}
              title={name}
              aria-label={name}
              class={[
                "size-6 cursor-pointer rounded-md ring-offset-2 ring-offset-panel transition-transform hover:scale-110",
                "data-[active]:ring-2 data-[active]:ring-accent",
                swatch
              ]}
            ></button>
          </div>
        </.style_row>

        <.style_row label="Fill" row="fill">
          <.segment style="fill" value="none" label="No fill">
            <.glyph name="fill-none" />
          </.segment>
          <.segment style="fill" value="tint" label="Tinted fill">
            <.glyph name="fill-tint" />
          </.segment>
        </.style_row>

        <.style_row label="Outline" row="stroke">
          <.segment style="stroke" value="solid" label="Solid">
            <.glyph name="stroke-solid" />
          </.segment>
          <.segment style="stroke" value="dashed" label="Dashed">
            <.glyph name="stroke-dashed" />
          </.segment>
        </.style_row>

        <.style_row label="Arrow heads" row="head">
          <.segment style="head" value="none" label="No heads, a plain line">
            <.glyph name="head-none" />
          </.segment>
          <.segment style="head" value="end" label="A head at the end">
            <.glyph name="head-end" />
          </.segment>
          <.segment style="head" value="both" label="A head at each end">
            <.glyph name="head-both" />
          </.segment>
        </.style_row>

        <.style_row label="Text size" row="size">
          <.segment
            :for={{size, label} <- [{"s", "S"}, {"m", "M"}, {"l", "L"}]}
            style="size"
            value={size}
            label={"Text size #{label}"}
          >
            <span class="text-[11px] font-semibold">{label}</span>
          </.segment>
        </.style_row>

        <div data-row="actions" class="flex items-center gap-1 border-t border-line-soft pt-2">
          <button
            type="button"
            data-action="front"
            title="Bring to front"
            aria-label="Bring to front"
            class={control_class()}
          >
            <.icon name="hero-bars-arrow-up" class="size-3.5" />
          </button>
          <button
            type="button"
            data-action="back"
            title="Send to back"
            aria-label="Send to back"
            class={control_class()}
          >
            <.icon name="hero-bars-arrow-down" class="size-3.5" />
          </button>
          <div class="flex-1"></div>
          <button
            type="button"
            data-action="duplicate"
            title="Duplicate (Ctrl+D)"
            aria-label="Duplicate"
            class={control_class()}
          >
            <.icon name="hero-document-duplicate" class="size-3.5" />
          </button>
          <button
            type="button"
            data-action="delete"
            title="Delete (Del)"
            aria-label="Delete"
            class={[control_class(), "hover:text-bad"]}
          >
            <.icon name="hero-trash" class="size-3.5" />
          </button>
        </div>
      </div>

      <button
        type="button"
        id="diagram-matches"
        data-role="matches"
        hidden
        title="Show the next match"
        class="absolute left-3 top-3 z-10 flex cursor-pointer items-center gap-1.5 rounded-full border border-warn/40 bg-panel/95 px-2.5 py-1 text-[11px] font-medium text-warn shadow-md shadow-black/10 backdrop-blur-sm transition-colors hover:bg-warn-soft/60"
      >
        <.icon name="hero-magnifying-glass" class="size-3" />
        <span data-role="match-count"></span>
      </button>

      <div class="absolute bottom-3 left-3 z-10 flex items-center gap-2">
        <div class={[floating_class(), "flex items-center gap-0.5 p-0.5"]}>
          <button
            type="button"
            data-zoom="out"
            title="Zoom out (Ctrl+scroll)"
            aria-label="Zoom out"
            class={control_class()}
          >
            <.icon name="hero-minus" class="size-3.5" />
          </button>
          <button
            type="button"
            id="diagram-zoom"
            data-zoom="reset"
            data-role="zoom-label"
            title="Reset zoom"
            class="h-7 w-12 cursor-pointer rounded-md font-mono text-[11px] text-muted transition-colors hover:bg-hover hover:text-ink"
          >
            100%
          </button>
          <button
            type="button"
            data-zoom="in"
            title="Zoom in (Ctrl+scroll)"
            aria-label="Zoom in"
            class={control_class()}
          >
            <.icon name="hero-plus" class="size-3.5" />
          </button>
          <span class="mx-0.5 h-4 w-px bg-line-soft"></span>
          <button
            type="button"
            data-zoom="fit"
            title="Zoom to fit (Shift+1)"
            aria-label="Zoom to fit"
            class={control_class()}
          >
            <.icon name="hero-arrows-pointing-out" class="size-3.5" />
          </button>
        </div>

        <div class={[floating_class(), "flex items-center gap-0.5 p-0.5"]}>
          <button
            type="button"
            data-action="undo"
            title="Undo (Ctrl+Z)"
            aria-label="Undo"
            disabled
            class={control_class()}
          >
            <.icon name="hero-arrow-uturn-left" class="size-3.5" />
          </button>
          <button
            type="button"
            data-action="redo"
            title="Redo (Ctrl+Y)"
            aria-label="Redo"
            disabled
            class={control_class()}
          >
            <.icon name="hero-arrow-uturn-right" class="size-3.5" />
          </button>
        </div>
      </div>

      <p class="pointer-events-none absolute bottom-4 right-4 z-10 hidden text-[11px] text-faint lg:block">
        Scroll or right drag to pan · Ctrl + scroll to zoom · Double click to write
      </p>
    </div>
    """
  end

  attr :tool, :string, required: true
  attr :label, :string, required: true
  attr :key, :string, default: nil
  attr :number, :string, default: nil
  slot :inner_block, required: true

  defp tool_button(assigns) do
    assigns =
      assign(
        assigns,
        :keys,
        [assigns.key, assigns.number] |> Enum.reject(&is_nil/1) |> Enum.join(" or ")
      )

    ~H"""
    <button
      type="button"
      id={"diagram-tool-#{@tool}"}
      data-tool={@tool}
      data-active={@tool == "select"}
      aria-pressed={to_string(@tool == "select")}
      title={"#{@label} (#{@keys})"}
      aria-label={@label}
      class="relative flex size-8 cursor-pointer items-center justify-center rounded-lg text-muted transition-colors hover:bg-hover hover:text-ink data-[active]:bg-accent-soft data-[active]:text-accent"
    >
      {render_slot(@inner_block)}
      <span
        :if={@number}
        class="pointer-events-none absolute bottom-0.5 right-1 font-mono text-[8px] leading-none text-faint"
      >
        {@number}
      </span>
    </button>
    """
  end

  attr :label, :string, required: true
  attr :row, :string, required: true
  slot :inner_block, required: true

  defp style_row(assigns) do
    ~H"""
    <div data-row={@row}>
      <p class="mb-1.5 text-[10px] font-semibold uppercase tracking-wider text-faint">{@label}</p>
      <div class="flex items-center gap-1">{render_slot(@inner_block)}</div>
    </div>
    """
  end

  attr :style, :string, required: true
  attr :value, :string, required: true
  attr :label, :string, required: true
  slot :inner_block, required: true

  defp segment(assigns) do
    ~H"""
    <button
      type="button"
      data-style={@style}
      data-value={@value}
      title={@label}
      aria-label={@label}
      class="flex h-7 flex-1 cursor-pointer items-center justify-center rounded-md border border-line text-muted transition-colors hover:bg-hover hover:text-ink data-[active]:border-accent/60 data-[active]:bg-accent-soft data-[active]:text-accent"
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

  # Drawing glyphs heroicons has no match for, in the same stroke style.
  attr :name, :string, required: true

  defp glyph(assigns) do
    ~H"""
    <svg
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="1.8"
      stroke-linecap="round"
      stroke-linejoin="round"
      aria-hidden="true"
      class="size-4"
    >
      <%= case @name do %>
        <% "select" -> %>
          <path d="M6 3.5 18.5 11l-5.75 1.75L10 18.5z" />
        <% "rectangle" -> %>
          <rect x="3.5" y="6" width="17" height="12" rx="2.5" />
        <% "diamond" -> %>
          <path d="M12 3.5 20.5 12 12 20.5 3.5 12z" />
        <% "ellipse" -> %>
          <ellipse cx="12" cy="12" rx="8.5" ry="7" />
        <% "arrow" -> %>
          <path d="M4.5 19.5 19 5M10.5 5H19v8.5" />
        <% "text" -> %>
          <path d="M5 7V5h14v2M12 5v14M9 19h6" />
        <% "table" -> %>
          <rect x="3.5" y="4.5" width="17" height="15" rx="2.5" />
          <path d="M3.5 9.5h17M9.5 9.5v10M3.5 14.5h17" />
        <% "head-none" -> %>
          <path d="M4 12h16" />
        <% "head-end" -> %>
          <path d="M4 12h15M15 8l4 4-4 4" />
        <% "head-both" -> %>
          <path d="M5 12h14M9 8l-4 4 4 4M15 8l4 4-4 4" />
        <% "fill-none" -> %>
          <rect x="4.5" y="4.5" width="15" height="15" rx="3" />
        <% "fill-tint" -> %>
          <rect x="4.5" y="4.5" width="15" height="15" rx="3" fill="currentColor" fill-opacity="0.3" />
        <% "stroke-solid" -> %>
          <path d="M4 12h16" />
        <% "stroke-dashed" -> %>
          <path d="M4 12h3m3.5 0h3m3.5 0h3" />
      <% end %>
    </svg>
    """
  end

  ## Events

  # The canvas asks for its diagram once it is mounted.
  @impl true
  def handle_event("editor_ready", _params, socket) do
    {:reply, document(socket), socket}
  end

  # After a reconnect the canvas still shows the diagram it had, which this
  # process, started afresh, may not know was open.
  @impl true
  def handle_event("editor_resume", %{"id" => id}, socket) do
    cond do
      id == socket.assigns.current.id or not Diagram.id?(id) ->
        {:noreply, socket}

      true ->
        case Library.get(socket.assigns.username, id) do
          {:ok, diagram} -> {:noreply, assign(socket, :current, current(diagram))}
          :error -> {:noreply, assign(socket, :current, current(Diagram.new(%{id: id}), false))}
        end
    end
  end

  # A save for the diagram open, or for the one just left: the canvas sends
  # what was pending before it switches. Anything else is a diagram deleted
  # meanwhile, and stays deleted.
  @impl true
  def handle_event("save", %{"id" => id, "elements" => elements}, socket)
      when is_list(elements) do
    %{username: username, current: current} = socket.assigns

    cond do
      id == current.id and not current.saved? and elements == [] ->
        {:noreply, socket}

      id == current.id ->
        {:ok, diagram} = Library.save(username, id, %{elements: elements})
        {:noreply, socket |> assign(:current, current(diagram)) |> assign_list()}

      match?({:ok, _diagram}, Library.get(username, id)) ->
        {:ok, _diagram} = Library.save(username, id, %{elements: elements})
        {:noreply, assign_list(socket)}

      true ->
        {:noreply, socket}
    end
  end

  # Naming a draft keeps it, even before anything is drawn in it.
  @impl true
  def handle_event("rename", %{"title" => title}, socket) do
    %{username: username, current: current} = socket.assigns

    if current.saved? or Diagram.title(title) != current.title do
      {:ok, diagram} = Library.save(username, current.id, %{title: title})
      {:noreply, socket |> assign(:current, current(diagram)) |> assign_list()}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("new_diagram", _params, socket) do
    {:noreply, open(socket, current(Diagram.new(), false), [])}
  end

  @impl true
  def handle_event("open_diagram", %{"id" => id}, socket) do
    socket = assign(socket, :menu, nil)

    if id == socket.assigns.current.id do
      {:noreply, socket}
    else
      case Library.get(socket.assigns.username, id) do
        {:ok, diagram} ->
          {:noreply, open(socket, current(diagram), diagram.elements)}

        :error ->
          {:noreply, socket |> assign_list() |> put_flash(:error, "That diagram is gone")}
      end
    end
  end

  @impl true
  def handle_event("duplicate_diagram", %{"id" => id}, socket) do
    socket = assign(socket, :menu, nil)

    case Library.duplicate(socket.assigns.username, id) do
      {:ok, copy} ->
        {:noreply, socket |> open(current(copy), copy.elements) |> assign_list()}

      :error ->
        {:noreply, socket |> assign_list() |> put_flash(:error, "That diagram is gone")}
    end
  end

  # Deleting the diagram open moves on to the one changed last.
  @impl true
  def handle_event("delete_diagram", %{"id" => id}, socket) do
    %{username: username, current: current} = socket.assigns
    _deleted = Library.delete(username, id)
    socket = socket |> assign(:menu, nil) |> assign_list()

    cond do
      id != current.id ->
        {:noreply, socket}

      match?({:ok, _diagram}, Library.latest(username)) ->
        {:ok, next} = Library.latest(username)
        {:noreply, open(socket, current(next), next.elements)}

      true ->
        {:noreply, open(socket, current(Diagram.new(), false), [])}
    end
  end

  # Searching narrows the list and marks the words on the canvas as well.
  @impl true
  def handle_event("search", %{"term" => term}, socket) do
    {:noreply, search(socket, term)}
  end

  @impl true
  def handle_event("clear_search", _params, socket) do
    {:noreply, search(socket, "")}
  end

  @impl true
  def handle_event("toggle_sidebar", _params, socket) do
    {:noreply, assign(socket, :sidebar?, !socket.assigns.sidebar?)}
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
  def handle_event("open_menu", %{"kind" => "diagram", "id" => id} = params, socket) do
    {:noreply, assign(socket, :menu, %{id: id, at: point(params), anchor: params["anchor"]})}
  end

  @impl true
  def handle_event("close_menu", _params, socket) do
    {:noreply, assign(socket, :menu, nil)}
  end

  ## Helpers

  @impl true
  def handle_info({:diagrams_changed, id}, socket) do
    socket = assign_list(socket)

    if socket.assigns.current.saved? and id in [:all, socket.assigns.current.id] do
      case Library.get(socket.assigns.username, socket.assigns.current.id) do
        {:ok, diagram} -> {:noreply, open(socket, current(diagram), diagram.elements)}
        :error -> {:noreply, open(socket, current(Diagram.new(), false), [])}
      end
    else
      {:noreply, socket}
    end
  end

  # Only what the page shows; the elements go to the canvas and stay there.
  defp current(%Diagram{} = diagram, saved? \\ true) do
    %{id: diagram.id, title: diagram.title, updated_at: diagram.updated_at, saved?: saved?}
  end

  defp open(socket, current, elements) do
    socket
    |> assign(:current, current)
    |> push_event("diagram:load", %{
      id: current.id,
      elements: elements,
      terms: Diagram.terms(socket.assigns.term)
    })
  end

  defp document(socket) do
    %{current: current, username: username, term: term} = socket.assigns

    elements =
      with true <- current.saved?,
           {:ok, diagram} <- Library.get(username, current.id) do
        diagram.elements
      else
        _draft -> []
      end

    %{id: current.id, elements: elements, terms: Diagram.terms(term)}
  end

  defp search(socket, term) do
    socket
    |> assign(:term, term)
    |> assign_list()
    |> push_event("diagram:highlight", %{terms: Diagram.terms(term)})
  end

  defp assign_list(socket) do
    entries =
      socket.assigns.username
      |> Library.list(socket.assigns.term)
      |> Enum.map(&Map.put(&1, :at, local(&1.updated_at)))

    assign(socket, groups: Utils.group_history(entries), count: length(entries))
  end

  # The wall clock time on this machine, which is what the day groups and
  # the times beside each diagram are read against.
  defp local(%DateTime{} = at) do
    at
    |> DateTime.to_naive()
    |> NaiveDateTime.to_erl()
    |> :calendar.universal_time_to_local_time()
    |> NaiveDateTime.from_erl!()
  end

  # A right click places the menu at the pointer; the keyboard anchors it to the row.
  defp point(%{"x" => x, "y" => y}) when is_number(x) and is_number(y), do: %{x: x, y: y}
  defp point(_params), do: nil

  defp time(at), do: Calendar.strftime(at, "%H:%M")

  defp elements(0), do: "Empty"
  defp elements(1), do: "1 element"
  defp elements(count), do: "#{count} elements"

  defp floating_class do
    "rounded-xl border border-line bg-panel/95 shadow-lg shadow-black/10 backdrop-blur-sm dark:shadow-black/40"
  end

  defp control_class do
    "flex size-7 cursor-pointer items-center justify-center rounded-md text-muted transition-colors hover:bg-hover hover:text-ink disabled:cursor-default disabled:opacity-35 disabled:hover:bg-transparent"
  end

  defp entry_action_class do
    "flex size-5 cursor-pointer items-center justify-center rounded text-faint transition-colors hover:bg-panel hover:text-accent"
  end
end
