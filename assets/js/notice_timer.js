// Each notice that leaves on its own keeps its own visible-time countdown,
// paused while it is hovered or focused. LiveView removes the hook when the
// notice is dismissed.
export const NoticeTimer = {
  mounted() {
    this.remaining = Number(this.el.dataset.timeout)
    this.pause = () => {
      if (this.timer === undefined) return
      clearTimeout(this.timer)
      this.timer = undefined
      this.remaining -= performance.now() - this.startedAt
    }
    this.resume = () => {
      if (this.timer !== undefined || this.el.matches(":hover") || this.el.contains(document.activeElement)) return
      this.startedAt = performance.now()
      this.timer = setTimeout(() => {
        this.timer = undefined
        this.pushEvent("dismiss_notice", {id: this.el.dataset.noticeId})
      }, Math.max(0, this.remaining))
    }

    this.el.addEventListener("mouseenter", this.pause)
    this.el.addEventListener("mouseleave", this.resume)
    this.el.addEventListener("focusin", this.pause)
    this.el.addEventListener("focusout", this.resume)
    this.resume()
  },

  destroyed() {
    clearTimeout(this.timer)
    this.el.removeEventListener("mouseenter", this.pause)
    this.el.removeEventListener("mouseleave", this.resume)
    this.el.removeEventListener("focusin", this.pause)
    this.el.removeEventListener("focusout", this.resume)
  },
}
