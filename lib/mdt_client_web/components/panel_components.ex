defmodule MDTClientWeb.PanelComponents do
  @moduledoc """
  Building blocks shared by the tool workspaces.

  Two things live here: the drag handle used to resize a neighbouring panel, and
  the tab strip both tools use so their tabs can be dragged into another order.

  Panel sizes are written to a CSS variable on `<html>`, outside anything
  LiveView patches, and persisted in local storage so they survive navigation
  and restarts. The pre-paint script in `root.html.heex` reads the same keys
  back.
  """
  use Phoenix.Component

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
end
