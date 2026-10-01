// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/mdt_client"
import topbar from "../vendor/topbar"
import {initZoom} from "./zoom"
import {NoticeTimer} from "./notice_timer"
import {CodeView} from "./code_view"
import {DiagramEditor} from "./diagram_editor"
import {CopyText} from "./copy_text"

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, NoticeTimer, CodeView, DiagramEditor, CopyText},
  // Modifier keys are not sent by default, but shortcuts like Ctrl+Enter need
  // them, and so do lists where Shift and Ctrl/Cmd clicks extend a selection.
  metadata: {
    click: (e, _el) => ({shiftKey: e.shiftKey, ctrlKey: e.ctrlKey, metaKey: e.metaKey}),
    keydown: (e, _el) => ({
      key: e.key,
      ctrlKey: e.ctrlKey,
      metaKey: e.metaKey,
      shiftKey: e.shiftKey,
      altKey: e.altKey,
      repeat: e.repeat,
    }),
  },
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#5ac1fe"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// Ctrl/Cmd +, - , 0 and Ctrl/Cmd + wheel resize the whole interface
initZoom()

// The desktop bar follows LiveView's page title and the theme resolved by the
// pre-paint script in root.html.heex.
const appWindow = window.__TAURI__?.window?.getCurrentWindow?.()
if (appWindow) {
  document.body.classList.add("tauri-window")

  let windowTitle
  const syncWindowTitle = () => {
    const browserTitle = document.title.trim()
    const pageTitle = browserTitle.endsWith(" · MDT")
      ? browserTitle.slice(0, -" · MDT".length)
      : browserTitle
    const title = pageTitle && pageTitle !== "MDT" ? `MDT | ${pageTitle}` : "MDT"
    if (title === windowTitle) return

    windowTitle = title
    document.getElementById("window-title").textContent = title
    appWindow.setTitle(title).catch(error => console.warn("Could not set window title", error))
  }

  new MutationObserver(syncWindowTitle).observe(document.head, {
    subtree: true,
    childList: true,
    characterData: true,
  })
  syncWindowTitle()

  for (const [id, action] of [
    ["window-minimize", () => appWindow.minimize()],
    ["window-maximize", () => appWindow.toggleMaximize()],
    ["window-close", () => appWindow.close()],
  ]) {
    document.getElementById(id)?.addEventListener("click", () => {
      action().catch(error => console.warn("Could not control window", error))
    })
  }

  document.querySelectorAll("#window-resize [data-resize-direction]").forEach(handle => {
    handle.addEventListener("mousedown", event => {
      if (event.button === 0) {
        appWindow.startResizeDragging(handle.dataset.resizeDirection)
          .catch(error => console.warn("Could not resize window", error))
      }
    })
  })

  const syncWindowTheme = () => {
    const theme = document.documentElement.dataset.theme
    if (theme === "light" || theme === "dark") {
      appWindow.setTheme(theme).catch(error => console.warn("Could not set window theme", error))
    }
  }

  new MutationObserver(syncWindowTheme).observe(document.documentElement, {
    attributes: true,
    attributeFilter: ["data-theme"],
  })
  syncWindowTheme()

  let restartingForUpdate = false
  const restartForUpdate = () => {
    if (restartingForUpdate) return
    restartingForUpdate = true
    window.__TAURI__.core.invoke("restart_app")
      .catch(error => {
        restartingForUpdate = false
        console.warn("Could not restart after update", error)
      })
  }
  window.addEventListener("phx:update-installed", restartForUpdate)
  window.addEventListener("mdt:restart-after-update", restartForUpdate)
}

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}
