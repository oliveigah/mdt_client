export const CopyText = {
  mounted() {
    this.onClick = async () => {
      const target = document.getElementById(this.el.dataset.copyTarget)
      if (!target) return
      try {
        await navigator.clipboard.writeText(target.textContent)
        this.el.textContent = "Copied"
      } catch (_error) {
        this.el.textContent = "Select and copy"
      }
      clearTimeout(this.resetTimer)
      this.resetTimer = setTimeout(() => { this.el.textContent = "Copy" }, 2000)
    }
    this.el.addEventListener("click", this.onClick)
  },
  destroyed() {
    clearTimeout(this.resetTimer)
    this.el.removeEventListener("click", this.onClick)
  },
}
