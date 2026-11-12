// Copies the text of the element `data-copy-target` names. The button says
// "Copied" for a moment; a child marked `data-copy-label` carries the words
// when the button also holds an icon.
export const CopyText = {
  mounted() {
    const label = () => this.el.querySelector("[data-copy-label]") || this.el
    this.idle = label().textContent
    this.onClick = async () => {
      const target = document.getElementById(this.el.dataset.copyTarget)
      if (!target) return
      try {
        await navigator.clipboard.writeText(target.textContent)
        label().textContent = "Copied"
      } catch (_error) {
        label().textContent = "Select and copy"
      }
      clearTimeout(this.resetTimer)
      this.resetTimer = setTimeout(() => { label().textContent = this.idle }, 2000)
    }
    this.el.addEventListener("click", this.onClick)
  },
  destroyed() {
    clearTimeout(this.resetTimer)
    this.el.removeEventListener("click", this.onClick)
  },
}
