import {highlightMarkdown} from "./markdown_highlight.js"

// A textarea with its Markdown coloured. The textarea stays what is typed
// into, so selection, IME and undo work as in any other field; its own text
// turns transparent once the colours are painted, on a layer behind it that
// copies its font, padding and wrapping.
//
// The layer is kept to the textarea's size less its scrollbar, so lines
// wrap at the same place, and follows its scrolling. It is drawn on every
// edit, before the browser paints, so a character typed never shows late.
//
//     <div class="group relative">
//       <div id="body-layer" phx-update="ignore" class="absolute left-0 top-0 overflow-hidden">
//         <div data-paint class="…the textarea's padding and type…"></div>
//       </div>
//       <textarea phx-hook="MarkdownEditor" data-layer="body-layer"
//         class="… group-has-[[data-painted]]:text-transparent"></textarea>
//     </div>
export const MarkdownEditor = {
  mounted() {
    this.layer = document.getElementById(this.el.dataset.layer)
    this.paint = this.layer.querySelector("[data-paint]")
    this.drawn = null

    this.el.addEventListener("input", () => this.draw())
    this.el.addEventListener("scroll", () => this.sync(), {passive: true})
    this.resizeObserver = new ResizeObserver(() => this.fit())
    this.resizeObserver.observe(this.el)

    this.draw()
  },

  // The body changed on the server, written from somewhere else.
  updated() {
    this.draw()
  },

  destroyed() {
    this.resizeObserver.disconnect()
  },

  draw() {
    const value = this.el.value
    if (value !== this.drawn) {
      this.drawn = value
      // A trailing line break makes a line of its own only with something on it.
      this.paint.innerHTML = highlightMarkdown(value) + (value.endsWith("\n") ? " " : "")
      this.paint.dataset.painted = ""
    }
    this.fit()
  },

  // The paint is at least as tall as the textarea's text, so the layer can
  // scroll as far as the textarea does.
  fit() {
    const {clientWidth, clientHeight, scrollHeight} = this.el
    this.layer.style.width = `${clientWidth}px`
    this.layer.style.height = `${clientHeight}px`
    this.paint.style.minHeight = `${scrollHeight}px`
    this.sync()
  },

  sync() {
    this.layer.scrollTop = this.el.scrollTop
    this.layer.scrollLeft = this.el.scrollLeft
  },
}
