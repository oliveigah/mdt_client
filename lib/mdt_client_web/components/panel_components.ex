defmodule MDTClientWeb.PanelComponents do
  @moduledoc """
  Building blocks shared by the tool workspaces.

  Three things live here: the drag handle used to resize a neighbouring panel,
  the tab strip both tools use so their tabs can be dragged into another order,
  and the context menu their lists open on a right click.

  Panel sizes are written to a CSS variable on `<html>`, outside anything
  LiveView patches, and persisted in local storage so they survive navigation
  and restarts. The pre-paint script in `root.html.heex` reads the same keys
  back.
  """
  use Phoenix.Component

  import MDTClientWeb.CoreComponents, only: [icon: 1]

  @doc """
  A drag handle that resizes the panel next to it.

  `edge` says where the panel sits relative to the handle: `"start"` when the
  handle follows the panel (the common left sidebar case) and `"end"` when the
  handle precedes it, as with a right hand inspector. Double clicking restores
  the default size.

  ## Examples

      <.resizer
        id="history-resizer"
        panel="history-panel"
        variable="--history-width"
        storage_key="mdt:history-width"
        axis="x"
        min="180"
        max="520"
      />
  """
  attr :id, :string, required: true
  attr :panel, :string, required: true, doc: "the DOM id of the panel being resized"
  attr :variable, :string, required: true, doc: "the CSS variable holding the size"
  attr :storage_key, :string, required: true
  attr :axis, :string, required: true, values: ~w(x y)
  attr :edge, :string, default: "start", values: ~w(start end)
  attr :min, :string, required: true
  attr :max, :string, required: true
  attr :label, :string, default: nil, doc: "an accessible name for the handle"

  def resizer(assigns) do
    ~H"""
    <div
      id={@id}
      phx-hook=".Resize"
      phx-update="ignore"
      role="separator"
      tabindex="0"
      aria-orientation={if @axis == "x", do: "vertical", else: "horizontal"}
      aria-label={@label || "Resize panel"}
      title="Drag to resize, double click to reset"
      data-panel={@panel}
      data-variable={@variable}
      data-key={@storage_key}
      data-axis={@axis}
      data-edge={@edge}
      data-min={@min}
      data-max={@max}
      class={[
        "shrink-0 transition-colors hover:bg-accent/30 data-[dragging]:bg-accent/50",
        "focus-visible:bg-accent/40 focus-visible:outline-none",
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
          this.fromEnd = this.el.dataset.edge === "end"
          this.min = parseInt(this.el.dataset.min, 10)
          this.max = parseInt(this.el.dataset.max, 10)
          this.step = 16
          this.frame = null
          this.pendingPoint = null

          this.clamp = (size) => Math.round(Math.max(this.min, Math.min(size, this.limit ?? this.max)))

          this.applySize = (size) => {
            this.size = `${size}px`
            document.documentElement.style.setProperty(this.variable, this.size)
          }

          this.commitSize = () => {
            this.frame = null
            if (!this.panel || this.pendingPoint === null) return

            const distance = (this.pendingPoint - this.origin) / this.scale
            this.applySize(this.clamp(this.fromEnd ? -distance : distance))
            this.pendingPoint = null
          }

          this.onMove = (event) => {
            if (!this.panel) return
            this.pendingPoint = this.horizontal ? event.clientX : event.clientY
            if (this.frame === null) this.frame = requestAnimationFrame(this.commitSize)
          }

          this.onUp = () => {
            if (this.frame !== null) {
              cancelAnimationFrame(this.frame)
              this.commitSize()
            }
            document.removeEventListener("pointermove", this.onMove)
            document.removeEventListener("pointerup", this.onUp)
            document.removeEventListener("pointercancel", this.onUp)
            document.body.style.userSelect = ""
            this.el.removeAttribute("data-dragging")
            if (this.size) { localStorage.setItem(this.storageKey, this.size) }
          }

          this.measure = () => {
            this.panel = document.getElementById(this.el.dataset.panel)
            if (!this.panel) return false

            const rect = this.panel.getBoundingClientRect()
            this.horizontal = this.axis === "x"
            this.scale =
              (this.horizontal
                ? rect.width / (this.panel.offsetWidth || 1)
                : rect.height / (this.panel.offsetHeight || 1)) || 1
            this.origin = this.horizontal
              ? (this.fromEnd ? rect.right : rect.left)
              : (this.fromEnd ? rect.bottom : rect.top)
            this.current = (this.horizontal ? rect.width : rect.height) / this.scale
            const room = (this.horizontal ? window.innerWidth * 0.6 : window.innerHeight * 0.7) / this.scale
            this.limit = Math.min(this.max, room)
            return true
          }

          this.el.addEventListener("pointerdown", (event) => {
            if (!this.measure()) return
            event.preventDefault()
            this.el.setAttribute("data-dragging", "")
            document.body.style.userSelect = "none"
            document.addEventListener("pointermove", this.onMove)
            document.addEventListener("pointerup", this.onUp)
            document.addEventListener("pointercancel", this.onUp)
          })

          // Arrow keys move the handle too, so the layout is reachable without a pointer.
          this.el.addEventListener("keydown", (event) => {
            const [back, forward] =
              this.axis === "x" ? ["ArrowLeft", "ArrowRight"] : ["ArrowUp", "ArrowDown"]
            if (event.key !== back && event.key !== forward) return
            if (!this.measure()) return

            event.preventDefault()
            const direction = (event.key === forward ? 1 : -1) * (this.fromEnd ? -1 : 1)
            this.applySize(this.clamp(this.current + direction * this.step))
            localStorage.setItem(this.storageKey, this.size)
          })

          this.el.addEventListener("dblclick", () => {
            document.documentElement.style.removeProperty(this.variable)
            localStorage.removeItem(this.storageKey)
            this.size = null
          })
        },

        destroyed() {
          if (this.frame !== null) cancelAnimationFrame(this.frame)
          document.removeEventListener("pointermove", this.onMove)
          document.removeEventListener("pointerup", this.onUp)
          document.removeEventListener("pointercancel", this.onUp)
        }
      }
    </script>
    """
  end

  @doc """
  A strip of tabs that can be dragged into another order.

  Each child must carry `draggable="true"` and a `data-sortable-id`. Dropping
  pushes `event` with the identifiers in their new order, which the LiveView
  applies; nothing is reordered in the browser, so the list on screen is always
  the one the server knows about.

  ## Examples

      <.tab_strip id="git-tabs" event="reorder_tabs" class="flex">
        <div :for={tab <- @tabs} draggable="true" data-sortable-id={tab.id}>...</div>
      </.tab_strip>
  """
  attr :id, :string, required: true
  attr :event, :string, default: "reorder_tabs"
  attr :class, :any, default: nil
  attr :rest, :global

  slot :inner_block, required: true

  def tab_strip(assigns) do
    ~H"""
    <div id={@id} phx-hook=".Reorder" data-event={@event} class={@class} {@rest}>
      {render_slot(@inner_block)}
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".Reorder">
      export default {
        mounted() {
          this.dragged = null

          this.el.addEventListener("dragstart", (event) => {
            const item = this.item(event.target)
            if (!item) return

            this.dragged = item.dataset.sortableId
            item.setAttribute("data-dragging", "")
            event.dataTransfer.effectAllowed = "move"
            event.dataTransfer.setData("text/plain", this.dragged)
          })

          this.el.addEventListener("dragover", (event) => {
            if (!this.dragged) return

            event.preventDefault()
            event.dataTransfer.dropEffect = "move"
            const over = this.item(event.target)
            this.mark(over, over && this.past(event, over))
          })

          this.el.addEventListener("drop", (event) => {
            if (!this.dragged) return

            event.preventDefault()
            const over = this.item(event.target)
            const order = this.order(over, over && this.past(event, over))
            this.clear()

            if (order) this.pushEvent(this.el.dataset.event, {order})
          })

          this.el.addEventListener("dragend", () => this.clear())
          this.el.addEventListener("dragleave", (event) => {
            if (!this.el.contains(event.relatedTarget)) this.mark(null)
          })
        },

        destroyed() { this.clear() },

        item(target) {
          const item = target.closest && target.closest("[data-sortable-id]")
          return item && this.el.contains(item) ? item : null
        },

        items() {
          return Array.from(this.el.querySelectorAll("[data-sortable-id]"))
        },

        // Past the middle of a tab means the dragged one belongs after it.
        past(event, item) {
          const box = item.getBoundingClientRect()
          return event.clientX > box.left + box.width / 2
        },

        order(over, past) {
          const ids = this.items().map((item) => item.dataset.sortableId)
          const rest = ids.filter((id) => id !== this.dragged)

          if (!over) return [...rest, this.dragged]

          const index = rest.indexOf(over.dataset.sortableId)
          if (index < 0) return null

          rest.splice(past ? index + 1 : index, 0, this.dragged)
          return rest
        },

        mark(over, past) {
          for (const item of this.items()) {
            if (item === over && item.dataset.sortableId !== this.dragged) {
              item.setAttribute("data-drop", past ? "after" : "before")
            } else {
              item.removeAttribute("data-drop")
            }
          }
        },

        clear() {
          this.dragged = null
          for (const item of this.items()) {
            item.removeAttribute("data-drop")
            item.removeAttribute("data-dragging")
          }
        }
      }
    </script>
    """
  end

  @doc "The classes a draggable tab needs for its drag and drop states."
  def tab_drag_classes do
    [
      "data-[dragging]:opacity-40",
      "data-[drop=before]:shadow-[inset_2px_0_0_0_var(--color-accent)]",
      "data-[drop=after]:shadow-[inset_-2px_0_0_0_var(--color-accent)]"
    ]
  end

  ## Context menus

  @doc """
  A context menu, meant to be rendered once at the root of a LiveView.

  Keeping it out of the scrolling panels means it is never clipped by them. It
  hangs off the pointer when opened by a right click (`at`), and off the
  element whose DOM id is `anchor` otherwise. Clicking elsewhere, scrolling or
  resizing pushes `close_menu`, so the LiveView must handle that event.

  Lists open it through the `MDTClientWeb.PanelComponents.RowMenu` hook: put the
  hook on the list, and `data-menu-kind` and `data-menu-id` (plus an optional
  `data-menu-side`) on each row. A right click, the menu key or Shift+F10 on a
  row pushes `open_menu` with those values, the row's id as `anchor`, and the
  pointer position. Arrow keys move between the list's `[role=option]` rows,
  and a list with `data-select-all="event"` pushes that event on Ctrl+A.
  """
  attr :id, :string, required: true
  attr :anchor, :string, required: true
  attr :label, :string, required: true
  attr :at, :any, default: nil, doc: "the pointer position the menu was opened from"
  slot :inner_block, required: true

  def context_menu(assigns) do
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
            } else if (event.key === "Escape") {
              // Focus sits in the menu, so it answers Escape on any page.
              this.pushEvent("close_menu", {})
            }
          })
        },

        items() {
          return Array.from(this.el.querySelectorAll("[role=menuitem]:not([disabled])"))
        }
      }
    </script>
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

            // A list that picks several rows at once picks all of them on Ctrl+A.
            if (this.el.dataset.selectAll && (event.ctrlKey || event.metaKey) && event.key === "a") {
              event.preventDefault()
              return this.pushEvent(this.el.dataset.selectAll, {})
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

        // The anchor says which control the menu came from, so a branch label in
        // the graph can stay unfolded while its menu is open. A file also says
        // which list it was in.
        openMenu(row, x, y) {
          const {menuKind: kind, menuId: id, menuSide: side} = row.dataset
          this.pushEvent("open_menu", {kind, id, side, anchor: row.id, x, y})
        }
      }
    </script>
    """
  end

  @doc "One entry of a `context_menu/1`."
  attr :id, :string, default: nil
  attr :icon, :string, required: true
  attr :danger, :boolean, default: false
  attr :disabled, :boolean, default: false
  attr :rest, :global
  slot :inner_block, required: true

  def menu_item(assigns) do
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

  @doc "A rule between groups of `menu_item/1`s."
  def menu_separator(assigns) do
    ~H"""
    <div class="my-1 h-px bg-line-soft" role="separator"></div>
    """
  end
end
