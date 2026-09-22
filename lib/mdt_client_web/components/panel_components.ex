defmodule MDTClientWeb.PanelComponents do
  @moduledoc """
  Building blocks shared by the tool workspaces.

  For now that is the drag handle used to resize a neighbouring panel. Sizes are
  written to a CSS variable on `<html>`, outside anything LiveView patches, and
  persisted in local storage so they survive navigation and restarts. The
  pre-paint script in `root.html.heex` reads the same keys back.
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
end
