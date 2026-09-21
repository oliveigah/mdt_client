// Interface zoom: Ctrl/Cmd with "+", "-", "0", or the mouse wheel.
//
// The Tauri webview has no browser chrome to zoom the page for us, so the app
// asks WebKit to change its native zoom level. This keeps resizing and scrolling
// on WebKit's fast rendering path instead of scaling and relaying out the body.
//
// A browser already zooms with the same shortcuts and will not let a page
// intercept them, so the handlers stay out of the way there and only run inside
// the desktop app. Set `mdt:force-zoom` in local storage to try them in a
// browser anyway.
const STEPS = [0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2]
const STORAGE_KEY = "mdt:zoom"
const DEFAULT = 1
// Enough wheel travel to move one step, so trackpad pinches do not fly past it.
const WHEEL_THRESHOLD = 50

let badge = null
let badgeTimer = null
let wheelDelta = 0
let zoomLevel = DEFAULT

export const currentZoom = () => zoomLevel

const applyCssFallback = (zoom) => {
  document.documentElement.style.setProperty("--zoom", zoom)
  document.body.classList.add("interface-zoom")
}

const applyRenderZoom = (zoom) => {
  document.documentElement.style.removeProperty("--zoom")
  document.body.classList.remove("interface-zoom")

  if (window.__TAURI_INTERNALS__?.invoke) {
    window.__TAURI_INTERNALS__.invoke("set_webview_zoom", {scale: zoom}).catch(() => applyCssFallback(zoom))
  } else if (window.__TAURI__?.core?.invoke) {
    window.__TAURI__.core.invoke("set_webview_zoom", {scale: zoom}).catch(() => applyCssFallback(zoom))
  } else {
    applyCssFallback(zoom)
  }
}

const applyZoom = (zoom) => {
  zoomLevel = zoom
  applyRenderZoom(zoom)

  if (zoom === DEFAULT) {
    localStorage.removeItem(STORAGE_KEY)
  } else {
    localStorage.setItem(STORAGE_KEY, zoom)
  }

  showBadge(zoom)
}

const stepZoom = (direction) => {
  const zoom = currentZoom()
  const closest = STEPS.reduce(
    (best, step, index) => (Math.abs(step - zoom) < Math.abs(STEPS[best] - zoom) ? index : best),
    0
  )
  const next = Math.min(STEPS.length - 1, Math.max(0, closest + direction))

  applyZoom(STEPS[next])
}

const showBadge = (zoom) => {
  if (!badge) {
    badge = document.createElement("div")
    badge.id = "zoom-badge"
    badge.setAttribute("aria-live", "polite")
    badge.className =
      "pointer-events-none fixed bottom-3 left-1/2 z-50 -translate-x-1/2 rounded-md border border-line bg-panel px-2.5 py-1 font-mono text-xs text-ink opacity-0 shadow-lg transition-opacity duration-150"
    document.body.appendChild(badge)
  }

  badge.textContent = `${Math.round(zoom * 100)}%`
  badge.style.opacity = "1"
  clearTimeout(badgeTimer)
  badgeTimer = setTimeout(() => (badge.style.opacity = "0"), 1200)
}

const ownsZoom = () =>
  !!(window.__TAURI__ || window.__TAURI_INTERNALS__) ||
  localStorage.getItem("mdt:force-zoom") === "true"

export const initZoom = () => {
  if (!ownsZoom()) return

  const savedZoom = parseFloat(localStorage.getItem(STORAGE_KEY))
  zoomLevel = Number.isFinite(savedZoom) && savedZoom >= 0.5 && savedZoom <= 3 ? savedZoom : DEFAULT
  applyRenderZoom(zoomLevel)

  window.addEventListener("keydown", (event) => {
    if (!event.ctrlKey && !event.metaKey) return

    if (event.key === "+" || event.key === "=") {
      event.preventDefault()
      stepZoom(1)
    } else if (event.key === "-" || event.key === "_") {
      event.preventDefault()
      stepZoom(-1)
    } else if (event.key === "0") {
      event.preventDefault()
      applyZoom(DEFAULT)
    }
  })

  window.addEventListener(
    "wheel",
    (event) => {
      if (!event.ctrlKey && !event.metaKey) return
      event.preventDefault()

      wheelDelta += event.deltaY
      if (Math.abs(wheelDelta) < WHEEL_THRESHOLD) return

      stepZoom(wheelDelta < 0 ? 1 : -1)
      wheelDelta = 0
    },
    {passive: false}
  )
}
