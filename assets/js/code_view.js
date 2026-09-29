import {JsonFormatter, escapeHtml, highlight} from "./json_format.js"

// Shows a response body: JSON is formatted and coloured, anything else, or
// the raw view, is the text as received.
//
// The server renders the body as plain text in a `[data-source]` element, which
// is also the raw view. Formatted JSON is drawn line by line, and only the
// lines in view are in the DOM, so a response of millions of lines scrolls as
// smoothly as a short one. Formatting runs in slices of a few milliseconds, so
// a large body never freezes the page while it is prepared.
//
// `data-language` ("json" or "text") and `data-format` ("pretty" or "raw") are
// read on every update, so switching views needs no new render of the body.

// Lines drawn past each edge of the viewport, so a fast scroll or a selection
// dragged past the edge does not meet blank space.
const OVERSCAN = 40
// Browsers cap the height of an element (WebKit near 33 million pixels,
// Firefox near 17 million). Beyond this height the scrollbar maps onto lines
// instead of every line getting pixels of its own.
const MAX_HEIGHT = 8_000_000
// Characters drawn of one line. The rest is in the raw view and in copies.
const MAX_LINE = 10_000
// Room above and below the lines, in pixels.
const PADDING = 6
// How long one formatting slice may hold the main thread.
const SLICE_MS = 12
const SLICE_CHARS = 1 << 18

// Runs `callback` as a new task: unlike setTimeout it is not held back by the
// 4ms minimum browsers put on nested timers, and the page still gets to paint
// in between.
const nextTask = (callback) => {
  const channel = new MessageChannel()
  channel.port1.onmessage = () => {
    channel.port1.close()
    callback()
  }
  channel.port2.postMessage(null)
  return channel
}

const element = (tag, className, attributes = {}) => {
  const node = document.createElement(tag)
  node.className = className
  for (const [name, value] of Object.entries(attributes)) node.setAttribute(name, value)
  return node
}

export const CodeView = {
  mounted() {
    this.source = this.el.querySelector("[data-source]")
    this.text = this.source ? this.source.textContent : ""
    this.formatter = null
    this.scroller = null
    this.allSelected = false

    // What the copy button next to the viewer copies: the view on screen.
    this.el.codeText = () => (this.prettyShown() ? this.formatter.text : this.text)

    this.apply()
  },

  updated() {
    this.apply()
  },

  destroyed() {
    this.unmounted = true
    this.resizeObserver?.disconnect()
    cancelAnimationFrame(this.frame)
  },

  wantsPretty() {
    return this.el.dataset.language === "json" && this.el.dataset.format !== "raw"
  },

  prettyShown() {
    return this.wantsPretty() && this.formatter?.done && !this.formatter.error
  },

  apply() {
    if (!this.wantsPretty()) return this.showRaw()
    if (!this.formatter) return this.format()
    if (this.formatter.done) this.formatter.error ? this.showInvalid() : this.showPretty()
  },

  // The raw text stays hidden meanwhile: laying out megabytes of wrapped text
  // would cost the browser more than formatting it.
  format() {
    this.formatter = new JsonFormatter(this.text)
    this.source?.setAttribute("hidden", "")

    const slice = () => {
      if (this.unmounted) return
      const deadline = performance.now() + SLICE_MS

      while (!this.formatter.step(SLICE_CHARS)) {
        if (performance.now() > deadline) {
          this.showProgress(this.formatter.progress)
          nextTask(slice)
          return
        }
      }

      this.showProgress(null)
      this.apply()
    }

    slice()
  },

  showRaw() {
    this.source?.removeAttribute("hidden")
    this.scroller?.setAttribute("hidden", "")
    this.setNotice(null)
  },

  showInvalid() {
    this.showRaw()
    this.setNotice("Not valid JSON, shown as received")
  },

  showPretty() {
    if (!this.scroller) this.build()

    this.source?.setAttribute("hidden", "")
    this.scroller.removeAttribute("hidden")
    this.setNotice(null)
    this.layout()
  },

  // A small pill in the corner, for formatting progress and notices.
  pill(name) {
    let pill = this.el.querySelector(`[data-pill=${name}]`)
    if (pill) return pill

    pill = element(
      "div",
      "pointer-events-none absolute right-3 top-2 z-10 rounded border px-1.5 py-0.5 font-sans text-[10px] shadow-sm",
      {"data-pill": name},
    )
    this.el.append(pill)
    return pill
  },

  showProgress(progress) {
    if (progress === null) return this.el.querySelector("[data-pill=progress]")?.remove()

    const pill = this.pill("progress")
    pill.classList.add("border-accent/40", "bg-accent-soft", "text-accent")
    pill.textContent = `Formatting… ${Math.floor(progress * 100)}%`
  },

  setNotice(message) {
    if (message === null) return this.el.querySelector("[data-pill=notice]")?.remove()

    const pill = this.pill("notice")
    pill.classList.add("border-warn/40", "bg-warn-soft", "text-warn")
    pill.textContent = message
  },

  build() {
    this.scroller = element(
      "div",
      "absolute inset-0 overflow-auto font-mono text-xs leading-5 outline-none",
      {tabindex: "0", role: "region", "aria-label": "Formatted response body"},
    )
    this.sizer = element("div", "relative")
    this.window = element("div", "absolute left-0 top-0 min-w-full")
    this.sizer.append(this.window)
    this.scroller.append(this.sizer)
    this.el.append(this.scroller)

    const digits = String(this.formatter.lineCount).length
    this.scroller.style.setProperty("--gutter", `${Math.max(3, digits) + 3}ch`)

    this.range = {start: 0, end: 0}
    this.scroller.addEventListener("scroll", () => this.schedule(), {passive: true})
    this.resizeObserver = new ResizeObserver(() => this.schedule())
    this.resizeObserver.observe(this.scroller)

    // Only the lines in view are in the DOM, so selecting everything and
    // copying it is done here rather than left to the browser.
    this.scroller.addEventListener("keydown", (event) => {
      const shortcut = event.ctrlKey || event.metaKey
      if (shortcut && event.key.toLowerCase() === "a") {
        event.preventDefault()
        this.selectAll(true)
      } else if (!["Control", "Meta", "Shift", "Alt"].includes(event.key) && !(shortcut && event.key.toLowerCase() === "c")) {
        this.selectAll(false)
      }
    })
    this.scroller.addEventListener("pointerdown", () => this.selectAll(false))
    this.scroller.addEventListener("copy", (event) => {
      if (!this.allSelected) return
      event.preventDefault()
      event.clipboardData.setData("text/plain", this.formatter.text)
    })
  },

  selectAll(selected) {
    this.allSelected = selected
    if (selected) this.selectWindow()
  },

  selectWindow() {
    const range = document.createRange()
    range.selectNodeContents(this.window)
    const selection = window.getSelection()
    selection.removeAllRanges()
    selection.addRange(range)
  },

  schedule() {
    if (this.frame) return
    this.frame = requestAnimationFrame(() => {
      this.frame = null
      this.draw()
    })
  },

  row(index, line) {
    const clipped = line.length > MAX_LINE
    const code = clipped ? escapeHtml(line.slice(0, MAX_LINE)) : highlight(line)
    const more = clipped
      ? `<span class="select-none text-faint"> … ${(line.length - MAX_LINE).toLocaleString()} more characters, see Raw</span>`
      : ""

    return (
      `<div class="flex h-5 hover:bg-panel/60">` +
      `<span class="sticky left-0 w-[var(--gutter)] shrink-0 select-none bg-deep pr-3 text-right text-ink/40 dark:text-ink/25">${index + 1}</span>` +
      `<code class="whitespace-pre pr-4">${code}${more}</code></div>`
    )
  },

  // Sizes the scroll area for the current body, then draws what is in view.
  layout() {
    if (!this.lineHeight) {
      this.window.innerHTML = this.row(0, "")
      this.lineHeight = this.window.firstElementChild.offsetHeight || 20
    }

    const lines = this.formatter.lineCount
    const width = Math.min(this.formatter.maxLength, MAX_LINE + 40)
    const height = lines * this.lineHeight + PADDING * 2

    this.scaled = height > MAX_HEIGHT
    this.height = Math.min(height, MAX_HEIGHT)
    this.sizer.style.height = `${this.height}px`
    this.sizer.style.width = `calc(var(--gutter) + ${width + 4}ch)`
    this.range = {start: 0, end: 0}
    this.draw()
  },

  draw() {
    if (!this.scroller || this.scroller.hidden) return

    const lines = this.formatter.lineCount
    const lineHeight = this.lineHeight
    const top = this.scroller.scrollTop
    const view = this.scroller.clientHeight
    const visible = Math.ceil(view / lineHeight) + 1

    let first
    if (this.scaled) {
      const progress = Math.min(1, top / Math.max(1, this.height - view))
      first = Math.floor(progress * Math.max(0, lines - visible + 1))
    } else {
      first = Math.floor(Math.max(0, top - PADDING) / lineHeight)
    }

    const last = Math.min(lines, first + visible)

    // While the lines in view are already drawn nothing changes, which keeps
    // a selection in place through small scrolls. A scaled scrollbar moves
    // the drawn lines with every pixel, so those are always redrawn.
    if (!this.scaled && first >= this.range.start && last <= this.range.end) return

    const start = Math.max(0, first - OVERSCAN)
    const end = Math.min(lines, last + OVERSCAN)
    const offset = this.scaled ? top - (first - start) * lineHeight : PADDING + start * lineHeight

    let html = ""
    for (let index = start; index < end; index++) html += this.row(index, this.formatter.line(index))

    this.range = {start, end}
    this.window.style.transform = `translateY(${offset}px)`
    this.window.innerHTML = html

    if (this.allSelected) this.selectWindow()
  },
}
