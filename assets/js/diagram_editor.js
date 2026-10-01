// The diagram canvas: shapes, tables, arrows and text drawn in SVG.
//
// The editor lives entirely in the browser, so dragging never waits on the
// server. The LiveView renders its chrome once, inside `phx-update="ignore"`,
// and from then on only hears about finished changes: each one sends the
// whole diagram with the "save" event, a moment after it lands. The server
// answers "editor_ready" with the diagram to show and pushes "diagram:load"
// when another is opened, and "diagram:highlight" as a search is typed.
//
// Elements are plain objects in the shape `MDTClient.Diagrams.Diagram`
// describes, drawn in order, so the last one is on top. Undo keeps whole
// snapshots of them, which for diagrams this size is simpler than diffing and
// still cheap.
//
// Nothing drawn takes pointer events: every press lands on the svg, and what
// is under it is worked out here, buttons drawn on the canvas included. In
// WebKit, a press on a node that the press itself redraws lands nowhere, and
// takes focus off the canvas.

import {
  FONT_SIZES,
  LINE_HEIGHT,
  TABLE_CELL_PADDING,
  arrowHead,
  arrowRoute,
  bounds,
  center,
  containsPoint,
  containsRect,
  distanceToBox,
  fontSize,
  handlePoints,
  headerBox,
  heightToFit,
  hitTest,
  inflate,
  innerBox,
  isArrow,
  isShape,
  isTable,
  lineHeight,
  matchingIds,
  normalizeRect,
  pointAlong,
  polylineDistance,
  portPoint,
  ports,
  resizeBox,
  resolveArrow,
  rowAt,
  rowBox,
  rowIndex,
  tableFont,
  tableHeaderHeight,
  tableHeight,
  tableMatches,
  tableRowHeight,
  unionBounds,
  wrapText,
} from "./diagram_geometry"

const SVG = "http://www.w3.org/2000/svg"
const SAVE_DELAY = 250
const NUDGE_SETTLE = 400
const HISTORY_LIMIT = 100
const MIN_ZOOM = 0.1
const MAX_ZOOM = 4
const GRID = 24
const FONT_WEIGHT = 500
const CLIPBOARD_TYPE = "mdt/diagram"
const DRAWING_TOOLS = ["rectangle", "ellipse", "diamond", "arrow", "text", "table"]
const DEFAULT_SIZES = {
  rectangle: {width: 160, height: 80},
  ellipse: {width: 150, height: 96},
  diamond: {width: 160, height: 104},
}
const TABLE_WIDTH = 220
const TABLE_MIN_TYPE = 36
const TABLE_MIN_NAME = 72
const TABLE_TITLE_WEIGHT = 600
const TYPE_WEIGHT = 400
const PLACEHOLDERS = {title: "Table name", type: "type", name: "name"}
const TOOL_KEYS = {
  v: "select", 1: "select",
  r: "rectangle", 2: "rectangle",
  d: "diamond", 3: "diamond",
  o: "ellipse", 4: "ellipse",
  a: "arrow", 5: "arrow",
  t: "text", 6: "text",
  7: "table",
  h: "hand",
}
const HANDLE_CURSORS = {
  nw: "nwse-resize", se: "nwse-resize", ne: "nesw-resize", sw: "nesw-resize",
  n: "ns-resize", s: "ns-resize", e: "ew-resize", w: "ew-resize",
}
// Ports, in screen pixels: how far out from an element they sit, how close a
// press must land to take one, and how near the pointer comes to show them.
const PORT_GAP = 16
const PORT_REACH = 9
const PORT_NEAR = 32

// Kept outside the hook so they outlive switching diagrams, and the editor
// being mounted again after visiting another tool.
let clipboard = null
const viewports = new Map()

const clamp = (value, min, max) => Math.min(max, Math.max(min, value))

const newId = () =>
  crypto.randomUUID?.() ?? `${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}`

const svg = (tag, attributes = {}) => {
  const node = document.createElementNS(SVG, tag)
  for (const [name, value] of Object.entries(attributes)) node.setAttribute(name, value)
  return node
}

const ink = (color) => `var(--color-${color})`
// Mixed into the canvas color rather than made translucent, so a filled
// shape hides what is behind it.
const tint = (color) => `color-mix(in oklab, var(--color-${color}) 16%, var(--color-deep))`

// Which style settings mean something for an element.
const applies = (key, element) =>
  key === "fill" ? isShape(element) || isTable(element)
    : key === "stroke" ? !isText(element)
      : key === "head" ? isArrow(element)
        : true

const isText = (element) => element.type === "text"

// Types are written smaller, in the monospaced face, and quieter than names.
const typeSize = (table) => tableFont(table) - 1

const blankRow = (row) => row.type.trim() === "" && row.name.trim() === ""

const samePort = (a, b) => !!a && !!b && a.id === b.id && a.row === b.row && a.side === b.side

// Fields with an undo of their own, which Ctrl+Z is left to.
const ownsUndo = (target) => target instanceof Element &&
  (target.isContentEditable || target.matches("input, textarea, select"))

export const DiagramEditor = {
  mounted() {
    const role = (name) => this.el.querySelector(`[data-role=${name}]`)
    this.svg = role("svg")
    this.viewport = role("viewport")
    this.scene = role("scene")
    this.overlay = role("overlay")
    this.portLayer = role("ports")
    this.grid = role("grid")
    this.textEditor = role("text-editor")
    this.stylePanel = role("style-panel")
    this.zoomLabel = role("zoom-label")
    this.emptyHint = role("empty-hint")
    this.matchButton = role("matches")
    this.matchCount = role("match-count")
    this.toolButtons = Array.from(this.el.querySelectorAll("[data-tool]"))
    this.styleButtons = Array.from(this.el.querySelectorAll("[data-style]"))
    this.rows = Object.fromEntries(
      Array.from(this.el.querySelectorAll("[data-row]"), (row) => [row.dataset.row, row])
    )
    this.undoButton = this.el.querySelector("[data-action=undo]")
    this.redoButton = this.el.querySelector("[data-action=redo]")

    this.font = getComputedStyle(this.el).fontFamily
    this.mono = getComputedStyle(this.el).getPropertyValue("--font-mono").trim() || "monospace"
    this.measurer = document.createElement("canvas").getContext("2d")

    this.docId = null
    this.elements = []
    this.selected = new Set()
    this.tool = "select"
    this.style = {color: "ink", fill: "none", stroke: "solid", size: "m", head: "end"}
    this.view = {x: 0, y: 0, zoom: 1}
    this.undoStack = []
    this.redoStack = []
    this.gesture = null
    this.editing = null
    this.hovered = null
    this.hoverHandle = null
    this.hoverRow = null
    this.hoverControl = null
    // The ports offered by the element near the pointer, and the one it is on.
    this.ports = []
    this.hoverPort = null
    this.hoverKey = null
    this.pointer = null
    this.spaceHeld = false
    this.terms = []
    this.matches = []
    this.matchIndex = -1
    this.nodes = new Map()
    this.labelBoxes = new Map()
    // The points each arrow is drawn through, and the buttons drawn on the
    // canvas itself, both rebuilt as the diagram changes.
    this.routes = new Map()
    this.controls = []
    this.dirty = false
    this.saveTimer = null
    this.nudgeSnapshot = null
    this.nudgeTimer = null
    this.pasteTimer = null
    this.frame = null
    this.cleanups = []

    this.on(this.svg, "pointerdown", (event) => this.pointerDown(event))
    this.on(this.svg, "pointermove", (event) => this.pointerMove(event))
    this.on(this.svg, "pointerup", (event) => this.pointerUp(event))
    this.on(this.svg, "pointercancel", () => this.cancelGesture())
    this.on(this.svg, "pointerleave", () => this.hover(null))
    this.on(this.svg, "dblclick", (event) => this.doubleClick(event))
    this.on(this.el, "wheel", (event) => this.wheel(event), {passive: false})
    this.on(this.el, "keydown", (event) => this.keyDown(event))
    this.on(this.el, "keyup", (event) => event.key === " " && this.holdSpace(false))
    // Undo and redo answer anywhere on the page, not only on the canvas.
    this.on(document, "keydown", (event) => !event.defaultPrevented && !ownsUndo(event.target) &&
      this.historyKey(event) && event.preventDefault())
    this.on(this.el, "click", (event) => this.chromeClick(event))
    // The webview's own menu only offers to reload the page.
    this.on(this.el, "contextmenu", (event) => event.preventDefault())
    // Pressing the canvas or a toolbar button leaves focus where it is: the
    // canvas takes it by hand in pointerDown, a text box opened by that press
    // keeps it, and restyling text being written does not end the writing.
    this.on(this.el, "mousedown", (event) => {
      if (event.target.closest("button") || this.svg.contains(event.target)) event.preventDefault()
    })
    this.on(this.textEditor, "input", () => this.editorInput())
    this.on(this.textEditor, "keydown", (event) => this.editorKeyDown(event))
    // Switching windows blurs the text box too; writing resumes on return.
    this.on(this.textEditor, "blur", () => document.hasFocus() && this.stopEditing())
    this.on(document, "copy", (event) => this.copyEvent(event))
    this.on(document, "paste", (event) => this.pasteEvent(event))
    // A press anywhere else, such as on another tool's link, sends what is
    // pending first, while this page is still there to send it.
    this.on(document, "pointerdown", (event) => !this.el.contains(event.target) && this.flushSave(), true)
    this.on(window, "blur", () => {
      this.holdSpace(false)
      this.flushSave()
    })
    this.on(window, "pagehide", () => this.flushSave())

    this.handleEvent("diagram:load", (diagram) => this.load(diagram))
    this.handleEvent("diagram:highlight", ({terms}) => this.highlight(terms, true))
    this.pushEvent("editor_ready", {}, (diagram) => this.load(diagram))
  },

  // The server may have restarted and forgotten which diagram is open, and
  // whatever was sent while it was away never arrived.
  reconnected() {
    if (!this.docId) return
    this.push("editor_resume", {id: this.docId})
    this.dirty = true
    this.flushSave()
  },

  destroyed() {
    this.stopEditing()
    this.flushSave()
    cancelAnimationFrame(this.frame)
    clearTimeout(this.nudgeTimer)
    clearTimeout(this.pasteTimer)
    this.cleanups.forEach((cleanup) => cleanup())
  },

  on(target, type, listener, options) {
    target.addEventListener(type, listener, options)
    this.cleanups.push(() => target.removeEventListener(type, listener, options))
  },

  push(event, payload) {
    try {
      this.pushEvent(event, payload)
    } catch (error) {
      console.warn(`Could not send ${event}`, error)
    }
  },

  // Loading

  load({id, elements, terms}) {
    this.stopEditing()
    this.settleNudge()
    this.flushSave()
    this.cancelGesture()

    this.docId = id
    this.elements = (elements || []).map((element) => ({...element}))
    // Measured again here, since the fonts may not be the ones it was drawn with.
    this.elements.forEach((element) => (isText(element) || isTable(element)) && this.layout(element))
    this.resolveArrows()
    this.selected = new Set()
    this.undoStack = []
    this.redoStack = []
    this.forgetHover()
    this.scene.replaceChildren()
    this.nodes.clear()
    this.labelBoxes.clear()

    this.view = viewports.get(id) || this.fittedView(unionBounds(this.elements))
    this.applyView()
    this.highlight(terms || [], true)
    this.render()
  },

  // Saving

  scheduleSave() {
    this.dirty = true
    clearTimeout(this.saveTimer)
    this.saveTimer = setTimeout(() => this.flushSave(), SAVE_DELAY)
  },

  flushSave() {
    clearTimeout(this.saveTimer)
    this.saveTimer = null
    if (!this.dirty || !this.docId) return

    this.dirty = false
    // A copy: should the socket be down, the payload waits in a buffer, and
    // later edits must not leak into it.
    this.push("save", {id: this.docId, elements: structuredClone(this.elements)})
  },

  // History

  snapshot() {
    return JSON.stringify(this.elements)
  },

  // Records the change made since `snapshot` as one undo step. Nothing is
  // recorded, or saved, when there was no change.
  commit(snapshot) {
    if (snapshot === this.snapshot()) return false

    this.undoStack.push(snapshot)
    if (this.undoStack.length > HISTORY_LIMIT) this.undoStack.shift()
    this.redoStack = []
    this.changed()
    return true
  },

  changed() {
    this.matches = matchingIds(this.elements, this.terms)
    if (this.matchIndex >= this.matches.length) this.matchIndex = this.matches.length ? 0 : -1
    this.scheduleSave()
    this.render()
  },

  undo() {
    this.settle()
    const previous = this.undoStack.pop()
    if (previous === undefined) return

    this.redoStack.push(this.snapshot())
    this.restore(previous)
  },

  redo() {
    this.settle()
    const next = this.redoStack.pop()
    if (next === undefined) return

    this.undoStack.push(this.snapshot())
    this.restore(next)
  },

  restore(snapshot) {
    this.elements = JSON.parse(snapshot)
    this.selected = new Set([...this.selected].filter((id) => this.find(id)))
    this.resolveArrows()
    this.changed()
  },

  // Finishes whatever is under way, so it becomes a step of its own.
  settle() {
    this.cancelGesture()
    this.stopEditing()
    this.settleNudge()
  },

  settleNudge() {
    if (this.nudgeSnapshot === null) return

    clearTimeout(this.nudgeTimer)
    const snapshot = this.nudgeSnapshot
    this.nudgeSnapshot = null
    this.commit(snapshot)
  },

  // Elements

  find(id) {
    return this.elements.find((element) => element.id === id)
  },

  selectedElements() {
    return this.elements.filter((element) => this.selected.has(element.id))
  },

  singleSelected() {
    return this.selected.size === 1 ? this.find([...this.selected][0]) : null
  },

  // What the style panel changes: the text being written, or the selection.
  styleTargets() {
    if (this.editing) return [this.find(this.editing.id)].filter(Boolean)
    return this.selectedElements()
  },

  add(attributes) {
    const {head, ...style} = this.style
    const element = {id: newId(), text: "", ...style, ...(attributes.type === "arrow" && {head}), ...attributes}
    this.elements.push(element)
    return element
  },

  // Moves elements together. An arrow moved without what it is attached to
  // comes loose from it.
  translate(elements, dx, dy) {
    const moving = new Set(elements.map((element) => element.id))

    for (const element of elements) {
      if (isArrow(element)) {
        if (element.start && !moving.has(element.start)) element.start = element.startRow = null
        if (element.end && !moving.has(element.end)) element.end = element.endRow = null
        element.x1 += dx
        element.y1 += dy
        element.x2 += dx
        element.y2 += dy
      } else {
        element.x += dx
        element.y += dy
      }
    }
  },

  // Brings every attached arrow end back onto its element, and lets go of the
  // ones whose element is gone. An end whose row is gone stays on the table.
  resolveArrows() {
    const byId = new Map(this.elements.map((element) => [element.id, element]))
    const lookup = (id) => {
      const element = byId.get(id)
      return element && !isArrow(element) ? element : null
    }

    this.routes.clear()
    for (const element of this.elements) {
      if (!isArrow(element)) continue
      if (element.start && !lookup(element.start)) element.start = null
      if (element.end && !lookup(element.end)) element.end = null
      if (rowIndex(lookup(element.start), element.startRow) < 0) element.startRow = null
      if (rowIndex(lookup(element.end), element.endRow) < 0) element.endRow = null
      if (element.start || element.end) Object.assign(element, resolveArrow(element, lookup))
      this.routes.set(element.id, arrowRoute(element, lookup))
    }
  },

  route(arrow) {
    return this.routes.get(arrow.id) || [{x: arrow.x1, y: arrow.y1}, {x: arrow.x2, y: arrow.y2}]
  },

  // Where a label goes: halfway along an arrow, in the middle of anything else.
  labelPoint(element) {
    return isArrow(element) ? pointAlong(this.route(element)) : center(element)
  },

  // Free text is exactly as big as what is written; a shape grows taller to
  // fit its text, and a table wider to fit its cells, but neither shrinks on
  // its own. A table is always as tall as its rows.
  layout(element) {
    const size = fontSize(element)

    if (isTable(element)) {
      const needs = this.tableNeeds(element)
      element.split = needs.split
      element.width = Math.max(element.width, needs.width)
      element.height = tableHeight(element)
    } else if (isText(element)) {
      const lines = element.text.split("\n")
      element.width = Math.max(size / 2, ...lines.map((line) => this.measure(line, size)))
      element.height = lines.length * lineHeight(element)
    } else if (isShape(element) && element.text.trim() !== "") {
      const needed = this.textLines(element).length * lineHeight(element)
      if (needed > innerBox(element).height) element.height = heightToFit(element, needed)
    }
  },

  measure(text, size, font = this.font, weight = FONT_WEIGHT) {
    this.measurer.font = `${weight} ${size}px ${font}`
    return this.measurer.measureText(text).width
  },

  // The type column fits the longest type; the table fits that, the longest
  // name and the title.
  tableNeeds(table) {
    const size = tableFont(table)
    const room = TABLE_CELL_PADDING * 2
    const widest = (texts, minimum, measure) => Math.max(minimum, ...texts.map(measure))

    const split = room + widest(table.rows.map((row) => row.type), TABLE_MIN_TYPE,
      (text) => this.measure(text, typeSize(table), this.mono, TYPE_WEIGHT))
    const names = room + widest(table.rows.map((row) => row.name), TABLE_MIN_NAME,
      (text) => this.measure(text, size))
    const title = room * 2 + this.measure(table.text || PLACEHOLDERS.title, size + 1, this.font, TABLE_TITLE_WEIGHT)

    return {split, width: Math.max(split + names, title)}
  },

  textLines(element) {
    const size = fontSize(element)
    const width = isShape(element) ? Math.max(innerBox(element).width, size) : Infinity
    return wrapText(element.text, width, (text) => this.measure(text, size))
  },

  // Hit testing

  tolerance() {
    return 6 / this.view.zoom
  },

  elementAt(point) {
    for (let index = this.elements.length - 1; index >= 0; index--) {
      const element = this.elements[index]
      const label = this.labelBoxes.get(element.id)
      const hit = isArrow(element)
        ? polylineDistance(this.route(element), point) <= this.tolerance() + 2
        : hitTest(element, point, this.tolerance())
      if (hit || (label && containsPoint(label, point))) return element
    }
    return null
  },

  // What an arrow end at `point` would attach to: the topmost element there,
  // and the row under it on a table. The end may not join the element the
  // other end is on, `other`, except from one of its rows to another.
  attachableAt(point, other = {}) {
    for (let index = this.elements.length - 1; index >= 0; index--) {
      const element = this.elements[index]
      if (isArrow(element) || !hitTest(element, point, this.tolerance())) continue

      const found = isTable(element) ? rowAt(element, point) : -1
      const row = found >= 0 ? element.rows[found].id : null
      if (element.id === other.id && !(row && other.row && row !== other.row)) continue
      return {element, row}
    }
    return null
  },

  // The part of a table under `point`: a cell of a row, or the title.
  cellAt(table, point) {
    const index = rowAt(table, point)
    if (index < 0) return {}
    return {row: table.rows[index].id, field: point.x < table.x + table.split ? "type" : "name"}
  },

  controlAt(point) {
    return this.controls.find((control) => containsPoint(control.box, point)) ?? null
  },

  handleAt(point) {
    const element = this.singleSelected()
    if (!element || this.editing) return null
    const reach = 7 / this.view.zoom

    if (isArrow(element)) {
      if (Math.hypot(point.x - element.x1, point.y - element.y1) <= reach) return {element, end: "start"}
      if (Math.hypot(point.x - element.x2, point.y - element.y2) <= reach) return {element, end: "end"}
      return null
    }

    for (const [handle, spot] of Object.entries(this.handles(element))) {
      if (Math.hypot(point.x - spot.x, point.y - spot.y) <= reach) return {element, handle}
    }
    return null
  },

  // A shape resizes from any side; a table, whose height follows its rows,
  // only sideways; anything else not at all.
  handles(element) {
    if (!isShape(element) && !isTable(element)) return {}
    const spots = handlePoints(this.handleBox(element))
    return isTable(element) ? {e: spots.e, w: spots.w} : spots
  },

  // Handles sit on the selection outline, just outside the shape.
  handleBox(element) {
    return inflate(bounds(element), 4 / this.view.zoom)
  },

  // Coordinates

  // The pointer relative to the canvas, in CSS pixels. The ratio undoes the
  // interface zoom, whichever way it is applied.
  local(event) {
    const box = this.el.getBoundingClientRect()
    const scale = box.width / (this.el.offsetWidth || 1) || 1
    return {x: (event.clientX - box.left) / scale, y: (event.clientY - box.top) / scale}
  },

  world(local) {
    return {x: (local.x - this.view.x) / this.view.zoom, y: (local.y - this.view.y) / this.view.zoom}
  },

  // Pointer gestures

  pointerDown(event) {
    // Dragging with the right or the middle button moves around the canvas,
    // whatever the tool, and leaves anything being written open.
    if (event.button === 1 || event.button === 2) {
      this.gesture = this.panGesture(event)
      this.svg.setPointerCapture(event.pointerId)
      this.updateCursor()
      this.renderOverlay()
      return
    }
    if (event.button !== 0) return

    const wasEditing = this.editing !== null
    this.el.focus({preventScroll: true})
    this.stopEditing()
    this.settleNudge()
    // The press that ends writing does nothing else, the way it would in a
    // text field.
    if (wasEditing && this.tool === "select") return

    const point = this.world(this.local(event))
    const snapshot = this.snapshot()
    this.pointer = point

    if (this.tool === "hand" || this.spaceHeld) {
      this.gesture = this.panGesture(event)
    } else if (this.tool === "select") {
      const control = this.controlAt(point)
      if (control) {
        control.run()
        this.hover(point)
        return
      }
      this.gesture = this.selectGesture(event, point)
    } else if (this.tool === "text") {
      this.setTool("select")
      this.createText(point)
      return
    } else if (this.tool === "arrow") {
      const target = this.attachableAt(point)
      this.gesture = this.arrowGesture(point, target && {id: target.element.id, row: target.row})
    } else if (this.tool === "table") {
      const table = this.add({type: "table", x: point.x, y: point.y, width: 0, height: 0, rows: [], split: 0})
      this.layout(table)
      this.selected = new Set()
      this.gesture = {kind: "create", id: table.id, origin: point}
    } else {
      const shape = this.add({type: this.tool, x: point.x, y: point.y, width: 0, height: 0})
      this.selected = new Set()
      this.gesture = {kind: "create", id: shape.id, origin: point}
    }

    if (this.gesture) {
      this.gesture.snapshot = snapshot
      this.svg.setPointerCapture(event.pointerId)
    }
    this.updateCursor()
    this.render()
  },

  selectGesture(event, point) {
    const grip = this.handleAt(point)
    if (grip?.handle) {
      // Measured from the shape's own corner, so the drag starts where it is.
      const spot = handlePoints(bounds(grip.element))[grip.handle]
      return {
        kind: "resize", id: grip.element.id, handle: grip.handle, box: bounds(grip.element),
        offset: {x: point.x - spot.x, y: point.y - spot.y},
      }
    }
    if (grip?.end) return {kind: "arrow", id: grip.element.id, end: grip.end}

    const port = this.portAt(point)
    if (port) return this.arrowGesture(point, port)

    const element = this.elementAt(point)
    if (element) {
      if (event.shiftKey && this.selected.has(element.id)) {
        this.selected.delete(element.id)
        return null
      }
      if (event.shiftKey) {
        this.selected.add(element.id)
      } else if (!this.selected.has(element.id)) {
        this.selected = new Set([element.id])
      }
      return {kind: "move", last: point}
    }

    if (!event.shiftKey) this.selected = new Set()
    return {kind: "marquee", origin: point, current: point, base: new Set(this.selected)}
  },

  panGesture(event) {
    return {kind: "pan", from: this.local(event), view: {...this.view}}
  },

  // Draws a new arrow out from `point`, its start attached to `from`, an
  // element and maybe one of its rows, when given.
  arrowGesture(point, from) {
    const arrow = this.add({
      type: "arrow", x1: point.x, y1: point.y, x2: point.x, y2: point.y,
      start: from?.id ?? null, startRow: from?.row ?? null, end: null, endRow: null,
    })
    this.selected = new Set()
    return {kind: "arrow", id: arrow.id, end: "end", origin: point, created: true}
  },

  pointerMove(event) {
    const local = this.local(event)
    const point = this.world(local)
    this.pointer = point
    const gesture = this.gesture

    if (!gesture) return this.hover(point)

    switch (gesture.kind) {
      case "pan":
        // A release the page never heard of, such as one over a menu, ends it.
        if (event.buttons === 0) return this.pointerUp(event)
        this.view = {
          ...gesture.view,
          x: gesture.view.x + local.x - gesture.from.x,
          y: gesture.view.y + local.y - gesture.from.y,
        }
        return this.applyView()

      case "move": {
        const dx = point.x - gesture.last.x
        const dy = point.y - gesture.last.y
        gesture.last = point
        this.translate(this.selectedElements(), dx, dy)
        break
      }

      case "resize": {
        const element = this.find(gesture.id)
        const target = {x: point.x - gesture.offset.x, y: point.y - gesture.offset.y}
        if (!element) break
        // A table is never narrower than what is written in it.
        const minimum = isTable(element) ? this.tableNeeds(element).width : 8
        Object.assign(element, resizeBox(gesture.box, gesture.handle, target, minimum))
        break
      }

      case "create": {
        const element = this.find(gesture.id)
        const {origin} = gesture
        // A table is dragged out sideways only; its rows set its height.
        if (element && isTable(element)) {
          element.x = Math.min(origin.x, point.x)
          element.width = Math.max(Math.abs(point.x - origin.x), this.tableNeeds(element).width)
          break
        }
        let corner = point
        // Shift draws squares and circles.
        if (event.shiftKey) {
          const side = Math.max(Math.abs(point.x - origin.x), Math.abs(point.y - origin.y))
          corner = {
            x: origin.x + (point.x < origin.x ? -side : side),
            y: origin.y + (point.y < origin.y ? -side : side),
          }
        }
        if (element) Object.assign(element, normalizeRect(origin, corner))
        break
      }

      case "arrow": {
        const arrow = this.find(gesture.id)
        if (!arrow) break
        const other = gesture.end === "end"
          ? {id: arrow.start, row: arrow.startRow}
          : {id: arrow.end, row: arrow.endRow}
        const target = this.attachableAt(point, other)
        const id = target?.element.id ?? null
        const row = target?.row ?? null
        gesture.target = target && {id, row}

        if (gesture.end === "end") {
          Object.assign(arrow, {x2: point.x, y2: point.y, end: id, endRow: row})
        } else {
          Object.assign(arrow, {x1: point.x, y1: point.y, start: id, startRow: row})
        }
        break
      }

      case "marquee": {
        gesture.current = point
        const area = normalizeRect(gesture.origin, point)
        this.selected = new Set(gesture.base)
        for (const element of this.elements) {
          if (containsRect(area, bounds(element))) this.selected.add(element.id)
        }
        break
      }
    }

    this.resolveArrows()
    this.requestRender()
  },

  pointerUp(event) {
    const gesture = this.gesture
    if (!gesture) return

    this.gesture = null
    if (this.svg.hasPointerCapture(event.pointerId)) this.svg.releasePointerCapture(event.pointerId)

    switch (gesture.kind) {
      case "create": {
        const element = this.find(gesture.id)
        if (!element) break
        // A new table goes straight to its name; the rows follow from there.
        if (isTable(element)) {
          if (Math.abs(this.pointer.x - gesture.origin.x) < 8) {
            element.width = TABLE_WIDTH
            element.x = gesture.origin.x - TABLE_WIDTH / 2
            element.y = gesture.origin.y - tableHeaderHeight(element) / 2
          }
          this.layout(element)
          this.setTool("select")
          this.startEditing(element.id, gesture.snapshot, {created: true})
          break
        }
        // A click rather than a drag drops a shape of the usual size there.
        if (element.width < 4 && element.height < 4) {
          const size = DEFAULT_SIZES[element.type]
          Object.assign(element, {
            x: gesture.origin.x - size.width / 2,
            y: gesture.origin.y - size.height / 2,
            ...size,
          })
        }
        this.selected = new Set([element.id])
        this.setTool("select")
        this.commit(gesture.snapshot)
        break
      }

      case "arrow": {
        const arrow = this.find(gesture.id)
        if (!arrow) break
        // Too short to be meant: a stray click with the arrow tool.
        const {origin} = gesture
        if (gesture.created && Math.hypot(this.pointer.x - origin.x, this.pointer.y - origin.y) < 8) {
          this.elements = this.elements.filter((element) => element.id !== arrow.id)
          break
        }
        this.selected = new Set([arrow.id])
        if (gesture.created) this.setTool("select")
        this.resolveArrows()
        this.commit(gesture.snapshot)
        break
      }

      case "move":
      case "resize":
        this.commit(gesture.snapshot)
        break
    }

    this.render()
    // What is under the pointer now, such as ports, shows again.
    this.hover(this.world(this.local(event)))
  },

  // Escape, or a lost pointer, puts back whatever the gesture changed.
  cancelGesture() {
    const gesture = this.gesture
    if (!gesture) return

    this.gesture = null
    if (gesture.snapshot && gesture.kind !== "pan" && gesture.kind !== "marquee") {
      this.elements = JSON.parse(gesture.snapshot)
      this.selected = new Set([...this.selected].filter((id) => this.find(id)))
      this.resolveArrows()
    }
    this.updateCursor()
    this.render()
  },

  doubleClick(event) {
    if (this.tool !== "select") return

    const point = this.world(this.local(event))
    // Two clicks on a port only draw nothing twice.
    if (this.portAt(point)) return

    const element = this.elementAt(point)
    if (element && isTable(element)) {
      this.startEditing(element.id, undefined, this.cellAt(element, point))
    } else if (element) {
      this.startEditing(element.id)
    } else {
      this.createText(point)
    }
  },

  hover(point) {
    const selecting = point && this.tool === "select" && !this.spaceHeld
    this.hoverControl = selecting ? this.controlAt(point) : null
    this.hoverHandle = selecting && !this.hoverControl ? this.handleAt(point) : null
    this.hoverPort = selecting && !this.hoverControl && !this.hoverHandle ? this.portAt(point) : null
    // While the pointer is on a port, its element keeps offering them, even
    // should another be nearer.
    if (!selecting || this.editing) this.ports = []
    else if (!this.hoverPort) this.ports = this.portsNear(point)

    const element = !selecting || this.hoverHandle ? null
      : this.hoverPort ? this.find(this.hoverPort.id) : this.elementAt(point)
    const hovered = element?.id ?? null

    // The row under the pointer on the selected table offers to be removed.
    const table = selecting && this.singleSelected()
    const hoverRow = table && isTable(table) ? (table.rows[rowAt(table, point)]?.id ?? null) : null

    const key = JSON.stringify([hovered, hoverRow, this.hoverControl?.name, this.ports, this.hoverPort])
    if (key !== this.hoverKey) {
      this.hoverKey = key
      this.hovered = hovered
      this.hoverRow = hoverRow
      this.renderOverlay()
    }
    this.updateCursor()
  },

  // Until the pointer next moves, nothing is under it.
  forgetHover() {
    this.hovered = null
    this.ports = []
    this.hoverPort = null
    this.hoverKey = null
  },

  updateCursor() {
    let cursor = "default"
    if (this.gesture?.kind === "pan") cursor = "grabbing"
    else if (this.tool === "hand" || this.spaceHeld) cursor = "grab"
    else if (this.tool === "text") cursor = "text"
    else if (this.tool !== "select") cursor = "crosshair"
    else if (this.hoverControl) cursor = "pointer"
    else if (this.hoverHandle?.handle) cursor = HANDLE_CURSORS[this.hoverHandle.handle]
    else if (this.hoverPort) cursor = "crosshair"
    else if (this.hoverHandle?.end || this.hovered) cursor = "move"
    this.svg.style.cursor = cursor
  },

  // Ports

  // The ports of the element under the pointer, or failing that of the
  // nearest one close enough. One drawn inside the element under the
  // pointer, as in a box around several, offers its own while the pointer is
  // near it. Arrows have none.
  portsNear(point) {
    const candidates = this.elements.filter((element) => !isArrow(element))
    const under = candidates.findLast((element) => hitTest(element, point, this.tolerance()))
    let host = under
    let nearest = PORT_NEAR / this.view.zoom

    for (const element of candidates) {
      if (element === under || (under && !containsRect(bounds(under), bounds(element)))) continue
      const distance = distanceToBox(bounds(element), point)
      if (distance <= nearest) {
        host = element
        nearest = distance
      }
    }
    return host ? ports(host, point) : []
  },

  portAt(point) {
    const reach = PORT_REACH / this.view.zoom
    return this.ports.find((port) => {
      const spot = this.portSpot(port)
      return spot && Math.hypot(point.x - spot.x, point.y - spot.y) <= reach
    }) ?? null
  },

  portSpot(port) {
    const element = this.find(port.id)
    return element ? portPoint(element, port, PORT_GAP / this.view.zoom) : null
  },

  // Panning and zooming. The wheel pans and Ctrl or Cmd with it zooms, as a
  // trackpad pinch does. It is kept from the window, where zoom.js would
  // zoom the whole interface instead.

  wheel(event) {
    event.preventDefault()
    event.stopPropagation()
    const unit = event.deltaMode === 1 ? 16 : event.deltaMode === 2 ? this.el.clientHeight : 1

    if (event.ctrlKey || event.metaKey) {
      this.zoomAt(this.local(event), Math.exp(-event.deltaY * unit * 0.0025))
      return
    }

    const sideways = event.shiftKey && event.deltaX === 0
    const dx = (sideways ? event.deltaY : event.deltaX) * unit
    const dy = (sideways ? 0 : event.deltaY) * unit
    this.view = {...this.view, x: this.view.x - dx, y: this.view.y - dy}
    this.applyView()
  },

  zoomAt(local, factor) {
    const zoom = clamp(this.view.zoom * factor, MIN_ZOOM, MAX_ZOOM)
    const world = this.world(local)
    this.view = {zoom, x: local.x - world.x * zoom, y: local.y - world.y * zoom}
    this.applyView()
  },

  zoomControl(kind) {
    const middle = {x: this.el.clientWidth / 2, y: this.el.clientHeight / 2}
    if (kind === "in") this.zoomAt(middle, 1.2)
    if (kind === "out") this.zoomAt(middle, 1 / 1.2)
    if (kind === "reset") this.zoomAt(middle, 1 / this.view.zoom)
    if (kind === "fit") this.fitContent()
  },

  fitContent() {
    const box = unionBounds(this.elements)
    if (!box) return
    this.view = this.fittedView(box)
    this.applyView()
  },

  // The view that shows `box` whole and centered, never enlarged past 100%.
  fittedView(box, maxZoom = 1) {
    const width = this.el.clientWidth
    const height = this.el.clientHeight
    if (!box) return {x: width / 2, y: height / 2, zoom: 1}

    const margin = 64
    const zoom = clamp(
      Math.min((width - margin * 2) / Math.max(box.width, 1), (height - margin * 2) / Math.max(box.height, 1)),
      MIN_ZOOM,
      maxZoom
    )
    return {
      zoom,
      x: width / 2 - (box.x + box.width / 2) * zoom,
      y: height / 2 - (box.y + box.height / 2) * zoom,
    }
  },

  // Brings `box` into view: centered at the current zoom when it fits there,
  // zoomed out to fit otherwise.
  reveal(box) {
    const {zoom} = this.view
    const width = this.el.clientWidth
    const height = this.el.clientHeight
    const fits = box.width * zoom < width - 96 && box.height * zoom < height - 96

    this.view = fits
      ? {zoom, x: width / 2 - (box.x + box.width / 2) * zoom, y: height / 2 - (box.y + box.height / 2) * zoom}
      : this.fittedView(box)
    this.applyView()
  },

  visible(box) {
    const {x, y, zoom} = this.view
    const left = box.x * zoom + x
    const top = box.y * zoom + y
    return left >= 0 && top >= 0 &&
      left + box.width * zoom <= this.el.clientWidth && top + box.height * zoom <= this.el.clientHeight
  },

  applyView() {
    const {x, y, zoom} = this.view
    this.viewport.setAttribute("transform", `translate(${x} ${y}) scale(${zoom})`)
    this.grid.style.backgroundSize = `${GRID * zoom}px ${GRID * zoom}px`
    this.grid.style.backgroundPosition = `${x}px ${y}px`
    // Dots closer than a few pixels read as noise.
    this.grid.style.opacity = zoom < 0.4 ? "0" : "1"
    this.zoomLabel.textContent = `${Math.round(zoom * 100)}%`
    if (this.docId) viewports.set(this.docId, {...this.view})
    if (this.editing) this.placeEditor()
    this.renderOverlay()
  },

  holdSpace(held) {
    if (this.spaceHeld === held) return
    this.spaceHeld = held
    this.updateCursor()
  },

  // Search highlights

  highlight(terms, reveal) {
    this.terms = terms
    this.matches = matchingIds(this.elements, terms)
    this.matchIndex = this.matches.length ? 0 : -1

    const first = this.matches.length && this.find(this.matches[0])
    if (reveal && first && !this.visible(bounds(first))) this.reveal(inflate(bounds(first), 24))
    this.renderOverlay()
    this.updateChrome()
  },

  nextMatch() {
    const count = this.matches.length
    if (count === 0) return

    this.matchIndex = (this.matchIndex + 1) % count
    const element = this.find(this.matches[this.matchIndex])
    if (element) this.reveal(inflate(bounds(element), 24))
    this.updateChrome()
  },

  // Writing

  createText(point) {
    const snapshot = this.snapshot()
    const size = FONT_SIZES[this.style.size] || FONT_SIZES.m
    const element = this.add({
      type: "text", x: point.x, y: point.y - (size * LINE_HEIGHT) / 2, width: 0, height: 0,
    })
    this.layout(element)
    this.startEditing(element.id, snapshot)
  },

  // Opens the text box over an element. On a table, `target` names the part
  // being written: `{}` for the title, `{row, field}` for a cell. `created`
  // marks a table just placed, which is taken away again if left empty.
  startEditing(id, snapshot = this.snapshot(), target = {}) {
    const element = this.find(id)
    if (!element) return

    this.stopEditing()
    this.selected = new Set([id])
    this.editing = {id, snapshot, row: target.row ?? null, field: target.field ?? null, created: !!target.created}
    this.textEditor.hidden = false
    this.fillEditor(element)
    this.textEditor.focus({preventScroll: true})
    this.textEditor.setSelectionRange(this.textEditor.value.length, this.textEditor.value.length)
    this.render()
  },

  fillEditor(element) {
    const {row, field} = this.editing
    const cell = isTable(element) && row ? element.rows.find((candidate) => candidate.id === row) : null

    this.textEditor.value = cell ? cell[field] : element.text
    this.editing.initial = this.textEditor.value
    this.textEditor.placeholder = !isTable(element) ? "" : cell ? PLACEHOLDERS[field] : PLACEHOLDERS.title
    this.placeEditor()
  },

  // A table follows what is typed into it as it is typed, growing to fit.
  editorInput() {
    const element = this.editing && this.find(this.editing.id)
    if (element && isTable(element)) {
      this.writeCell(element, this.editing, this.textEditor.value)
      this.layout(element)
      this.resolveArrows()
      this.requestRender()
    }
    this.placeEditor()
  },

  writeCell(table, {row, field}, value) {
    const text = value.replace(/[\r\n]+/g, " ")
    const cell = row && table.rows.find((candidate) => candidate.id === row)
    if (cell) cell[field] = text
    else if (!row) table.text = text
  },

  // Lays the text box over the element, in the same font and size, so the
  // text stays put when the box goes away.
  placeEditor() {
    const element = this.editing && this.find(this.editing.id)
    if (!element) return
    if (isTable(element)) return this.placeCellEditor(element)

    const input = this.textEditor
    const {x: panX, y: panY, zoom} = this.view
    const size = fontSize(element)
    const lines = input.value.split("\n")
    const widest = Math.max(size, ...lines.map((line) => this.measure(line, size))) * zoom
    const middle = this.labelPoint(element)

    Object.assign(input.style, {
      font: `${FONT_WEIGHT} ${size * zoom}px ${this.font}`,
      lineHeight: String(LINE_HEIGHT),
      color: ink(element.color),
    })

    let left, top, width, height
    if (isShape(element)) {
      const box = innerBox(element)
      width = Math.max(box.width, size) * zoom
      input.style.whiteSpace = "pre-wrap"
      input.style.textAlign = "center"
      input.style.width = `${width}px`
      input.style.height = "0px"
      height = input.scrollHeight
      left = middle.x * zoom + panX - width / 2
      top = middle.y * zoom + panY - height / 2
    } else {
      width = widest + size * zoom
      height = lines.length * size * zoom * LINE_HEIGHT
      input.style.whiteSpace = "pre"
      if (element.type === "text") {
        input.style.textAlign = "left"
        left = element.x * zoom + panX
        top = element.y * zoom + panY
      } else {
        input.style.textAlign = "center"
        left = middle.x * zoom + panX - width / 2
        top = middle.y * zoom + panY - height / 2
      }
    }

    Object.assign(input.style, {
      left: `${left}px`, top: `${top}px`, width: `${width}px`, height: `${height}px`,
    })
  },

  // Over the title or a cell, with the cell's own font, so nothing moves when
  // the box goes away.
  placeCellEditor(table) {
    const {x: panX, y: panY, zoom} = this.view
    const {row, field} = this.editing
    const index = rowIndex(table, row)
    const line = index >= 0 ? rowBox(table, index) : null
    const type = field === "type"

    const box = !line ? headerBox(table)
      : type ? {...line, width: table.split}
        : {...line, x: line.x + table.split, width: line.width - table.split}
    const size = !line ? tableFont(table) + 1 : type ? typeSize(table) : tableFont(table)
    const weight = !line ? TABLE_TITLE_WEIGHT : type ? TYPE_WEIGHT : FONT_WEIGHT
    const height = size * LINE_HEIGHT
    const pad = TABLE_CELL_PADDING

    Object.assign(this.textEditor.style, {
      font: `${weight} ${size * zoom}px ${type ? this.mono : this.font}`,
      lineHeight: String(LINE_HEIGHT),
      color: type ? "var(--color-muted)" : ink(table.color),
      whiteSpace: "pre",
      textAlign: line ? "left" : "center",
      left: `${(box.x + pad) * zoom + panX}px`,
      top: `${(box.y + (box.height - height) / 2) * zoom + panY}px`,
      width: `${Math.max(box.width - pad * 2, 1) * zoom}px`,
      height: `${height * zoom}px`,
    })
  },

  editorKeyDown(event) {
    // Ctrl+Z undoes typing in the box as usual. With nothing typed there
    // yet, it closes the box the way Escape does, so the next one undoes on
    // the canvas; a row or text just added and left empty goes with it.
    const untouched = this.editing && this.textEditor.value === this.editing.initial
    const undoing = (event.ctrlKey || event.metaKey) && !event.shiftKey && !event.altKey &&
      event.key.toLowerCase() === "z"
    if (untouched && undoing) {
      event.preventDefault()
      return this.finishEditing()
    }

    const element = this.editing && this.find(this.editing.id)
    if (element && isTable(element)) return this.tableKeyDown(event, element)

    const done = event.key === "Escape" || (event.key === "Enter" && (event.ctrlKey || event.metaKey))
    if (!done) return

    event.preventDefault()
    this.stopEditing()
    this.el.focus({preventScroll: true})
  },

  // Writing a table the way a spreadsheet is written: Tab moves from the
  // title to the type, the name and on to the next row, Enter to the next
  // row, adding one at the end, and Alt with the arrows moves a row.
  tableKeyDown(event, table) {
    const vertical = event.key === "ArrowUp" ? -1 : event.key === "ArrowDown" ? 1 : 0
    let handled = true

    if (event.key === "Escape") this.finishEditing()
    else if (event.key === "Tab") this.moveCell(table, event.shiftKey ? "back" : "forward")
    else if (event.key === "Enter") this.moveCell(table, event.shiftKey ? "up" : "down")
    else if (event.altKey && vertical) this.moveRow(table, vertical)
    else handled = false

    if (handled) event.preventDefault()
  },

  finishEditing() {
    this.stopEditing()
    this.el.focus({preventScroll: true})
  },

  moveCell(table, direction) {
    this.writeCell(table, this.editing, this.textEditor.value)
    const {row, field} = this.editing
    const index = rowIndex(table, row)
    const current = table.rows[index]
    const last = index === table.rows.length - 1

    // Going on past an empty last row means the table is done.
    if (current && last && blankRow(current) && (direction === "down" || (direction === "forward" && field === "name"))) {
      return this.finishEditing()
    }

    let next
    if (direction === "forward") {
      next = !current ? this.rowCell(table, 0) : field === "type" ? {row, field: "name"} : this.rowCell(table, index + 1)
    } else if (direction === "down") {
      next = this.rowCell(table, index + 1)
    } else if (direction === "back") {
      next = !current ? null : field === "name" ? {row, field: "type"} : index === 0 ? {} : {row: table.rows[index - 1].id, field: "name"}
    } else {
      next = !current ? null : index === 0 ? {} : {row: table.rows[index - 1].id, field: "type"}
    }
    if (next) this.focusCell(table, next)
  },

  // The type cell of row `index`, adding the row when it is one past the end.
  rowCell(table, index) {
    if (index >= table.rows.length) table.rows.push({id: newId(), type: "", name: ""})
    return {row: table.rows[index].id, field: "type"}
  },

  focusCell(table, next) {
    const left = this.editing.row
    this.editing = {...this.editing, row: next.row ?? null, field: next.field ?? null}
    if (left && left !== this.editing.row) this.pruneRow(table, left)

    this.layout(table)
    this.resolveArrows()
    this.scheduleSave()
    this.render()
    this.fillEditor(table)
    this.textEditor.select()
  },

  moveRow(table, step) {
    this.writeCell(table, this.editing, this.textEditor.value)
    const index = rowIndex(table, this.editing.row)
    const target = index + step
    if (index < 0 || target < 0 || target >= table.rows.length) return

    const [row] = table.rows.splice(index, 1)
    table.rows.splice(target, 0, row)
    this.resolveArrows()
    this.scheduleSave()
    this.render()
    this.placeEditor()
  },

  // A row left with nothing in it goes, the way empty free text does.
  pruneRow(table, rowId) {
    const row = table.rows.find((candidate) => candidate.id === rowId)
    if (row && blankRow(row)) table.rows = table.rows.filter((candidate) => candidate !== row)
  },

  addRow(table) {
    const snapshot = this.snapshot()
    const row = {id: newId(), type: "", name: ""}
    table.rows.push(row)
    this.layout(table)
    this.resolveArrows()
    this.startEditing(table.id, snapshot, {row: row.id, field: "type"})
  },

  removeRow(table, rowId) {
    const snapshot = this.snapshot()
    table.rows = table.rows.filter((row) => row.id !== rowId)
    this.hoverRow = null
    this.layout(table)
    this.resolveArrows()
    this.commit(snapshot)
  },

  // Keeps what was written. Free text left empty is removed, as if it had
  // never been placed.
  stopEditing() {
    const editing = this.editing
    if (!editing) return

    this.editing = null
    // Hiding the box would drop focus on the page; the canvas takes it back.
    if (document.activeElement === this.textEditor) this.el.focus({preventScroll: true})
    this.textEditor.hidden = true
    const value = this.textEditor.value.replace(/\r\n/g, "\n")
    const element = this.find(editing.id)
    const abandoned = element && isTable(element) && editing.created

    if (element && isTable(element)) this.writeCell(element, editing, value)
    if (element && isTable(element) && editing.row) this.pruneRow(element, editing.row)

    if (element && ((isText(element) && value.trim() === "") ||
        (abandoned && element.text.trim() === "" && element.rows.length === 0))) {
      this.elements = this.elements.filter((other) => other.id !== element.id)
      this.selected.delete(element.id)
    } else if (element && isTable(element)) {
      this.layout(element)
    } else if (element) {
      element.text = value
      this.layout(element)
    }

    this.resolveArrows()
    this.commit(editing.snapshot)
    this.render()
  },

  // Keyboard

  keyDown(event) {
    if (event.target !== this.el) return

    const key = event.key.toLowerCase()
    // Undo and redo are left to the page's own listener, historyKey.
    if (event.ctrlKey || event.metaKey) {
      if (key === "d") this.duplicate()
      else if (key === "a") this.selectAll()
      else if (key === "x") this.cut()
      // Copying and pasting also go through the clipboard events, which carry
      // the system clipboard; these keep them working where the webview does
      // not fire those events outside text fields.
      else if (key === "c") return void this.copyToClipboard()
      else if (key === "v") return void this.pasteSoon()
      else return
      return event.preventDefault()
    }
    if (event.altKey) return

    const nudge = event.shiftKey ? 10 : 1
    switch (event.key) {
      case "Delete":
      case "Backspace":
        this.deleteSelected()
        break
      case "Escape":
        this.escape()
        break
      case "Enter": {
        const element = this.singleSelected()
        if (!element) return
        this.startEditing(element.id)
        break
      }
      case "ArrowLeft": this.nudge(-nudge, 0); break
      case "ArrowRight": this.nudge(nudge, 0); break
      case "ArrowUp": this.nudge(0, -nudge); break
      case "ArrowDown": this.nudge(0, nudge); break
      case " ":
        this.holdSpace(true)
        break
      default:
        if (event.shiftKey && event.code === "Digit1") {
          this.fitContent()
          break
        }
        if (event.shiftKey || !TOOL_KEYS[key]) return
        this.setTool(TOOL_KEYS[key])
    }
    event.preventDefault()
  },

  // Ctrl+Z undoes, and Ctrl+Y or Ctrl+Shift+Z redo, with Cmd for Ctrl on a
  // Mac. Says whether the key was one of them.
  historyKey(event) {
    if (!(event.ctrlKey || event.metaKey) || event.altKey) return false

    const key = event.key.toLowerCase()
    if (key === "z" && event.shiftKey) this.redo()
    else if (key === "z") this.undo()
    else if (key === "y") this.redo()
    else return false
    return true
  },

  escape() {
    if (this.gesture) return this.cancelGesture()
    if (this.selected.size) {
      this.selected = new Set()
    } else if (this.tool !== "select") {
      this.setTool("select")
    }
    this.render()
  },

  nudge(dx, dy) {
    const picked = this.selectedElements()
    if (picked.length === 0) return

    // A held arrow key is one undo step, not one per pixel.
    if (this.nudgeSnapshot === null) this.nudgeSnapshot = this.snapshot()
    this.translate(picked, dx, dy)
    this.resolveArrows()
    this.render()
    clearTimeout(this.nudgeTimer)
    this.nudgeTimer = setTimeout(() => this.settleNudge(), NUDGE_SETTLE)
  },

  // Actions

  setTool(tool) {
    this.stopEditing()
    this.tool = tool
    if (tool !== "select") this.selected = new Set()
    this.forgetHover()
    this.updateCursor()
    this.render()
  },

  selectAll() {
    this.selected = new Set(this.elements.map((element) => element.id))
    this.render()
  },

  deleteSelected() {
    if (this.selected.size === 0) return

    const snapshot = this.snapshot()
    this.elements = this.elements.filter((element) => !this.selected.has(element.id))
    this.selected = new Set()
    this.resolveArrows()
    this.commit(snapshot)
  },

  arrange(toFront) {
    if (this.selected.size === 0) return

    const snapshot = this.snapshot()
    const picked = this.selectedElements()
    const rest = this.elements.filter((element) => !this.selected.has(element.id))
    this.elements = toFront ? [...rest, ...picked] : [...picked, ...rest]
    this.commit(snapshot)
  },

  applyStyle(key, value) {
    this.style = {...this.style, [key]: value}
    const targets = this.styleTargets().filter((element) => applies(key, element))
    if (targets.length === 0) return this.updateChrome()

    const snapshot = this.snapshot()
    for (const element of targets) {
      element[key] = value
      if (key === "size") this.layout(element)
    }
    this.resolveArrows()
    this.commit(snapshot)

    // What is still being written is judged against the restyled diagram.
    if (this.editing) {
      this.editing.snapshot = this.snapshot()
      this.placeEditor()
    }
  },

  duplicate() {
    this.insertCopies(this.selectedElements(), 16, 16)
  },

  // Adds copies of `elements` moved by (dx, dy), and selects them. Arrows
  // stay attached to whatever was copied along with them.
  insertCopies(elements, dx, dy) {
    if (elements.length === 0) return

    const snapshot = this.snapshot()
    const ids = new Map(elements.map((element) => [element.id, newId()]))
    // Deep copies: a table's rows must not be shared with the original.
    const copies = elements.map((element) => ({...structuredClone(element), id: ids.get(element.id)}))

    for (const copy of copies) {
      if (isArrow(copy)) {
        copy.start = ids.get(copy.start) ?? null
        copy.end = ids.get(copy.end) ?? null
        if (!copy.start) copy.startRow = null
        if (!copy.end) copy.endRow = null
      }
    }
    this.translate(copies, dx, dy)

    this.elements.push(...copies)
    this.selected = new Set(copies.map((copy) => copy.id))
    this.resolveArrows()
    this.commit(snapshot)
  },

  // Clipboard. Copied elements are kept here as well as on the system
  // clipboard, which the webview may refuse to write.

  copySelection() {
    const picked = this.selectedElements()
    if (picked.length === 0) return null

    clipboard = JSON.stringify({type: CLIPBOARD_TYPE, elements: picked})
    return clipboard
  },

  copyToClipboard() {
    const data = this.copySelection()
    if (data) navigator.clipboard?.writeText(data).catch(() => {})
  },

  cut() {
    this.copyToClipboard()
    this.deleteSelected()
  },

  copyEvent(event) {
    if (document.activeElement !== this.el) return
    const data = this.copySelection()
    if (!data) return

    event.clipboardData.setData("text/plain", data)
    event.preventDefault()
  },

  // Waits a moment for the paste event, which brings whatever the system
  // clipboard holds, before falling back on what was copied here.
  pasteSoon() {
    clearTimeout(this.pasteTimer)
    this.pasteTimer = setTimeout(() => this.paste(clipboard), 0)
  },

  pasteEvent(event) {
    if (document.activeElement !== this.el) return

    clearTimeout(this.pasteTimer)
    event.preventDefault()
    this.paste(event.clipboardData?.getData("text/plain") || clipboard)
  },

  // Elements copied from a diagram come back as they were, around the
  // pointer; any other text becomes a text element there.
  paste(text) {
    if (!text?.trim()) return

    let elements = null
    try {
      const data = JSON.parse(text)
      if (data?.type === CLIPBOARD_TYPE && Array.isArray(data.elements)) elements = data.elements
    } catch (_notOurs) {
      elements = null
    }

    const spot = this.pointer || this.world({x: this.el.clientWidth / 2, y: this.el.clientHeight / 2})

    if (elements) {
      const box = unionBounds(elements)
      if (!box) return
      this.insertCopies(elements, spot.x - (box.x + box.width / 2), spot.y - (box.y + box.height / 2))
      return
    }

    const snapshot = this.snapshot()
    const element = this.add({type: "text", x: spot.x, y: spot.y, width: 0, height: 0, text: text.trimEnd()})
    this.layout(element)
    this.selected = new Set([element.id])
    this.commit(snapshot)
  },

  // The chrome rendered by the LiveView: tools, style, zoom and history.
  chromeClick(event) {
    const button = event.target.closest("button")
    if (!button || !this.el.contains(button)) return

    const {tool, style, value, action, zoom} = button.dataset
    if (tool) this.setTool(tool)
    else if (style) this.applyStyle(style, value)
    else if (zoom) this.zoomControl(zoom)
    else if (button === this.matchButton) this.nextMatch()
    else if (action === "undo") this.undo()
    else if (action === "redo") this.redo()
    else if (action === "duplicate") this.duplicate()
    else if (action === "delete") this.deleteSelected()
    else if (action === "front") this.arrange(true)
    else if (action === "back") this.arrange(false)
  },

  // Rendering

  requestRender() {
    if (this.frame) return
    this.frame = requestAnimationFrame(() => {
      this.frame = null
      this.render()
    })
  },

  render() {
    if (this.frame) {
      cancelAnimationFrame(this.frame)
      this.frame = null
    }
    this.renderScene()
    this.renderOverlay()
    this.updateChrome()
  },

  // Each element keeps its own group, redrawn only when the element changed,
  // and the groups follow the elements' order.
  renderScene() {
    const present = new Set()

    this.elements.forEach((element, index) => {
      present.add(element.id)
      let node = this.nodes.get(element.id)
      if (!node) {
        node = {group: svg("g"), key: null}
        this.nodes.set(element.id, node)
      }

      const editing = this.editing?.id === element.id ? `#editing:${this.editing.row}:${this.editing.field}` : ""
      const route = isArrow(element) ? JSON.stringify(this.route(element)) : ""
      const key = JSON.stringify(element) + route + editing
      if (node.key !== key) {
        this.draw(node.group, element)
        node.key = key
      }

      const current = this.scene.children[index]
      if (current !== node.group) this.scene.insertBefore(node.group, current ?? null)
    })

    for (const [id, node] of this.nodes) {
      if (present.has(id)) continue
      node.group.remove()
      this.nodes.delete(id)
      this.labelBoxes.delete(id)
    }
  },

  draw(group, element) {
    group.replaceChildren()
    this.labelBoxes.delete(element.id)

    const outline = (shape, filled = true) => {
      shape.style.stroke = ink(element.color)
      shape.style.fill = filled && element.fill === "tint" ? tint(element.color) : "none"
      shape.setAttribute("stroke-width", "2")
      shape.setAttribute("stroke-linejoin", "round")
      shape.setAttribute("stroke-linecap", "round")
      if (element.stroke === "dashed") shape.setAttribute("stroke-dasharray", "8 6")
      return shape
    }

    const {x, y, width, height} = element
    switch (element.type) {
      case "rectangle":
        group.append(outline(svg("rect", {
          x, y, width, height, rx: Math.max(0, Math.min(8, width / 4, height / 4)),
        })))
        break

      case "ellipse":
        group.append(outline(svg("ellipse", {
          cx: x + width / 2, cy: y + height / 2, rx: width / 2, ry: height / 2,
        })))
        break

      case "diamond":
        group.append(outline(svg("polygon", {
          points: `${x + width / 2},${y} ${x + width},${y + height / 2} ${x + width / 2},${y + height} ${x},${y + height / 2}`,
        })))
        break

      case "arrow": {
        const route = this.route(element)
        const points = (list) => list.map((point) => `${point.x},${point.y}`).join(" ")
        group.append(outline(svg("polyline", {points: points(route)}), false))

        for (const [tip, before] of this.arrowTips(element, route)) {
          const head = outline(svg("polyline", {points: points(this.barbs(route, tip, before))}), false)
          head.removeAttribute("stroke-dasharray")
          group.append(head)
        }
        break
      }

      case "table":
        return this.drawTable(group, element)
    }

    if (element.text && this.editing?.id !== element.id) this.drawText(group, element)
  },

  // The ends that get a head, each with the point the line comes from.
  arrowTips(arrow, route) {
    const last = route.length - 1
    const start = [route[0], route[1]]
    const end = [route[last], route[last - 1]]
    return arrow.head === "none" ? [] : arrow.head === "both" ? [start, end] : [end]
  },

  // Sized against the whole arrow, not just its last stretch, which on a row
  // is only the short run out of the table.
  barbs(route, tip, before) {
    const length = route.slice(1).reduce((sum, point, index) =>
      sum + Math.hypot(point.x - route[index].x, point.y - route[index].y), 0)
    const reach = Math.min(14, length / 2)
    const run = Math.hypot(tip.x - before.x, tip.y - before.y) || 1
    const from = {x: tip.x - ((tip.x - before.x) / run) * reach * 2, y: tip.y - ((tip.y - before.y) / run) * reach * 2}
    return arrowHead(from.x, from.y, tip.x, tip.y, reach)
  },

  drawTable(group, table) {
    const {x, y, width, height, split} = table
    const header = tableHeaderHeight(table)
    const step = tableRowHeight(table)
    const pad = TABLE_CELL_PADDING
    const color = ink(table.color)
    const editing = this.editing?.id === table.id ? this.editing : null
    const dashed = table.stroke === "dashed" ? {"stroke-dasharray": "8 6"} : {}
    const radius = Math.min(8, height / 4)

    // Opaque, so relation lines running behind a table do not show through.
    const body = svg("rect", {x, y, width, height, rx: radius})
    body.style.fill = table.fill === "tint" ? tint(table.color) : "var(--color-deep)"

    // Square at the bottom where rows follow, rounded like the body otherwise.
    const band = svg("path", {
      d: table.rows.length
        ? `M${x} ${y + header}V${y + radius}Q${x} ${y} ${x + radius} ${y}H${x + width - radius}` +
          `Q${x + width} ${y} ${x + width} ${y + radius}V${y + header}Z`
        : `M${x} ${y + radius}Q${x} ${y} ${x + radius} ${y}H${x + width - radius}Q${x + width} ${y} ${x + width} ${y + radius}` +
          `V${y + height - radius}Q${x + width} ${y + height} ${x + width - radius} ${y + height}H${x + radius}` +
          `Q${x} ${y + height} ${x} ${y + height - radius}Z`,
    })
    band.style.fill = `color-mix(in oklab, ${color} 22%, var(--color-deep))`
    group.append(body, band)

    const rule = (x1, y1, x2, y2, opacity) => {
      const line = svg("line", {x1, y1, x2, y2, "stroke-width": 1, "stroke-opacity": opacity})
      line.style.stroke = color
      group.append(line)
    }
    if (table.rows.length) {
      rule(x, y + header, x + width, y + header, 0.7)
      rule(x + split, y + header, x + split, y + height, 0.25)
      for (let index = 1; index < table.rows.length; index++) {
        rule(x, y + header + index * step, x + width, y + header + index * step, 0.18)
      }
    }

    const outline = svg("rect", {x, y, width, height, rx: radius, "stroke-width": 2, ...dashed})
    outline.style.stroke = color
    outline.style.fill = "none"
    group.append(outline)

    const write = (content, attributes, style) => {
      const text = svg("text", {"dominant-baseline": "central", ...attributes})
      Object.assign(text.style, {whiteSpace: "pre", ...style})
      text.textContent = content
      group.append(text)
    }

    if (!(editing && !editing.row)) {
      write(table.text || PLACEHOLDERS.title, {
        x: x + width / 2, y: y + header / 2, "text-anchor": "middle",
        "font-size": tableFont(table) + 1, "font-weight": TABLE_TITLE_WEIGHT,
      }, {fill: table.text ? color : "var(--color-faint)", fontFamily: this.font})
    }

    table.rows.forEach((row, index) => {
      const middle = y + header + step * (index + 0.5)
      const being = (field) => editing?.row === row.id && editing.field === field

      if (row.type && !being("type")) {
        write(row.type, {x: x + pad, y: middle, "font-size": typeSize(table), "font-weight": TYPE_WEIGHT},
          {fill: "var(--color-muted)", fontFamily: this.mono})
      }
      if (row.name && !being("name")) {
        write(row.name, {x: x + split + pad, y: middle, "font-size": tableFont(table), "font-weight": FONT_WEIGHT},
          {fill: color, fontFamily: this.font})
      }
    })
  },

  drawText(group, element) {
    const size = fontSize(element)
    const step = lineHeight(element)
    const lines = this.textLines(element)
    const middle = this.labelPoint(element)
    const free = element.type === "text"
    const anchorX = free ? element.x : middle.x
    const top = free ? element.y : middle.y - (lines.length * step) / 2

    const text = svg("text", {
      "font-size": size,
      "font-weight": FONT_WEIGHT,
      "text-anchor": free ? "start" : "middle",
      "dominant-baseline": "central",
    })
    text.style.fill = ink(element.color)
    text.style.fontFamily = this.font
    text.style.whiteSpace = "pre"

    lines.forEach((line, index) => {
      const span = svg("tspan", {x: anchorX, y: top + step * (index + 0.5)})
      span.textContent = line
      text.append(span)
    })

    // An arrow's label sits on a patch of canvas that cuts the line behind it.
    if (isArrow(element)) {
      const width = Math.max(...lines.map((line) => this.measure(line, size)))
      const box = {x: anchorX - width / 2 - 6, y: top - 2, width: width + 12, height: lines.length * step + 4}
      const patch = svg("rect", {...box, rx: 4})
      patch.style.fill = "var(--color-deep)"
      group.append(patch)
      this.labelBoxes.set(element.id, box)
    }

    group.append(text)
  },

  // Selection, handles, hover, search matches and the marquee, drawn over
  // the scene with strokes that keep their width at any zoom.
  renderOverlay() {
    const zoom = this.view.zoom
    const parts = []
    const frame = (box, className, attributes = {}) => {
      parts.push(svg("rect", {
        ...box, rx: 6 / zoom, class: className, "vector-effect": "non-scaling-stroke", ...attributes,
      }))
    }

    // On a table the match is marked on the rows that hold it.
    this.matches.forEach((id, index) => {
      const element = this.find(id)
      if (!element) return
      const tone = index === this.matchIndex ? "fill-warn/15 stroke-warn stroke-2" : "fill-warn/10 stroke-warn/60"
      if (!isTable(element)) return frame(inflate(bounds(element), 8 / zoom), tone)

      const found = tableMatches(element, this.terms)
      if (found.title) frame(inflate(headerBox(element), 2 / zoom), tone)
      for (const row of found.rows) frame(inflate(rowBox(element, row), 2 / zoom), tone)
    })

    const hovered = this.hovered && !this.selected.has(this.hovered) && !this.gesture && this.find(this.hovered)
    if (hovered) frame(inflate(bounds(hovered), 4 / zoom), "fill-none stroke-accent/40")

    const target = this.gesture?.kind === "arrow" && this.gesture.target
    const attaching = target && this.find(target.id)
    if (attaching) {
      const row = rowIndex(attaching, target.row)
      const box = row >= 0 ? inflate(rowBox(attaching, row), 2 / zoom) : inflate(bounds(attaching), 5 / zoom)
      frame(box, "fill-accent/10 stroke-accent stroke-2")
    }

    const selected = this.selectedElements()
    if (selected.length === 1 && isArrow(selected[0])) {
      const {x1, y1, x2, y2} = selected[0]
      for (const [cx, cy] of [[x1, y1], [x2, y2]]) {
        parts.push(svg("circle", {
          cx, cy, r: 5 / zoom, class: "fill-deep stroke-accent stroke-2", "vector-effect": "non-scaling-stroke",
        }))
      }
    } else if (selected.length > 0) {
      if (selected.length > 1) {
        for (const element of selected) frame(inflate(bounds(element), 3 / zoom), "fill-none stroke-accent/50")
      }
      const box = selected.length === 1 ? this.handleBox(selected[0]) : inflate(unionBounds(selected), 8 / zoom)
      frame(box, "fill-none stroke-accent", {"stroke-dasharray": "4 3"})

      if (selected.length === 1 && !this.editing) {
        const side = 8 / zoom
        for (const spot of Object.values(this.handles(selected[0]))) {
          parts.push(svg("rect", {
            x: spot.x - side / 2, y: spot.y - side / 2, width: side, height: side, rx: 2 / zoom,
            class: "fill-deep stroke-accent stroke-[1.5]", "vector-effect": "non-scaling-stroke",
          }))
        }
      }
    }

    if (this.gesture?.kind === "marquee") {
      frame(normalizeRect(this.gesture.origin, this.gesture.current), "fill-accent/10 stroke-accent/60", {rx: 0})
    }

    this.controls = []
    const table = selected.length === 1 && isTable(selected[0]) && !this.editing && !this.gesture && selected[0]
    if (table) parts.push(...this.tableControls(table))

    this.overlay.replaceChildren(...parts)
    this.renderPorts()
  },

  // Buttons drawn by the selected table: one under it to add a row, and one
  // on the row under the pointer to remove it. They keep their size at any
  // zoom, and pointerDown finds them through `this.controls`.
  tableControls(table) {
    const zoom = this.view.zoom
    const unscaled = {"vector-effect": "non-scaling-stroke"}
    const lit = (name) => this.hoverControl?.name === name
    const parts = []

    const width = 28 / zoom
    const height = 18 / zoom
    const add = {x: table.x + table.width / 2 - width / 2, y: table.y + table.height + 10 / zoom, width, height}
    const arm = 4 / zoom
    const middle = {x: add.x + width / 2, y: add.y + height / 2}
    parts.push(
      svg("rect", {
        ...add, rx: height / 2, ...unscaled,
        class: lit("add-row") ? "fill-accent-soft stroke-accent" : "fill-panel stroke-accent/70",
      }),
      svg("path", {
        d: `M${middle.x - arm} ${middle.y}H${middle.x + arm}M${middle.x} ${middle.y - arm}V${middle.y + arm}`,
        class: "fill-none stroke-accent stroke-2", "stroke-linecap": "round", ...unscaled,
      })
    )
    this.controls.push({name: "add-row", box: add, run: () => this.addRow(table)})

    const index = rowIndex(table, this.hoverRow)
    if (index >= 0) {
      const line = rowBox(table, index)
      const radius = 7 / zoom
      const spot = {x: line.x + line.width - 13 / zoom, y: line.y + line.height / 2}
      const cross = 2.5 / zoom
      parts.push(
        svg("circle", {
          cx: spot.x, cy: spot.y, r: radius, ...unscaled,
          class: lit("remove-row") ? "fill-bad-soft stroke-bad" : "fill-panel stroke-bad/60",
        }),
        svg("path", {
          d: `M${spot.x - cross} ${spot.y - cross}L${spot.x + cross} ${spot.y + cross}` +
            `M${spot.x + cross} ${spot.y - cross}L${spot.x - cross} ${spot.y + cross}`,
          class: "fill-none stroke-bad stroke-[1.5]", "stroke-linecap": "round", ...unscaled,
        })
      )
      const rowId = table.rows[index].id
      this.controls.push({
        name: "remove-row",
        box: {x: spot.x - radius, y: spot.y - radius, width: radius * 2, height: radius * 2},
        run: () => this.removeRow(table, rowId),
      })
    }

    return parts
  },

  // Ports have a layer of their own, where they stay put while the pointer
  // moves around them, so they fade in once as it comes near, and light up
  // smoothly as it lands on one.
  renderPorts() {
    const offered = this.tool === "select" && !this.gesture && !this.editing && !this.spaceHeld
    const shown = offered ? this.ports.filter((port) => this.find(port.id)) : []
    const layer = this.portLayer
    const host = shown[0]?.id ?? ""

    if (layer.dataset.host !== host || layer.childElementCount !== shown.length) {
      layer.dataset.host = host
      layer.replaceChildren(...shown.map(() => svg("circle", {
        class: "fill-panel stroke-accent/70 stroke-[1.5] transition-[opacity,fill,stroke,stroke-width] " +
          "duration-150 ease-out starting:opacity-0 data-[active]:fill-accent data-[active]:stroke-accent/25 " +
          "data-[active]:stroke-[7]",
        "vector-effect": "non-scaling-stroke",
      })))
    }

    shown.forEach((port, index) => {
      const spot = this.portSpot(port)
      const active = samePort(port, this.hoverPort)
      const node = layer.children[index]
      node.setAttribute("cx", spot.x)
      node.setAttribute("cy", spot.y)
      node.setAttribute("r", (active ? 5.5 : 4) / this.view.zoom)
      node.toggleAttribute("data-active", active)
    })
  },

  updateChrome() {
    for (const button of this.toolButtons) {
      const active = button.dataset.tool === this.tool
      button.toggleAttribute("data-active", active)
      button.setAttribute("aria-pressed", String(active))
    }

    // With nothing selected, the panel sets the style of what is drawn next.
    const targets = this.styleTargets()
    const drawing = DRAWING_TOOLS.includes(this.tool)
    const subjects = targets.length ? targets : drawing ? [{type: this.tool, ...this.style}] : []
    this.stylePanel.hidden = subjects.length === 0

    if (subjects.length) {
      this.rows.fill.hidden = !subjects.some((subject) => applies("fill", subject))
      this.rows.stroke.hidden = !subjects.some((subject) => applies("stroke", subject))
      this.rows.head.hidden = !subjects.some(isArrow)
      this.rows.actions.hidden = targets.length === 0 || this.editing !== null

      for (const button of this.styleButtons) {
        const {style: key, value} = button.dataset
        const values = new Set(subjects.filter((subject) => applies(key, subject)).map((subject) => subject[key]))
        const active = values.size === 1 && values.has(value)
        button.toggleAttribute("data-active", active)
        button.setAttribute("aria-pressed", String(active))
      }
    }

    this.emptyHint.hidden = this.elements.length > 0
    this.undoButton.disabled = this.undoStack.length === 0
    this.redoButton.disabled = this.redoStack.length === 0

    this.matchButton.hidden = this.terms.length === 0
    const count = this.matches.length
    this.matchCount.textContent =
      count === 0 ? "No matches here"
        : count === 1 ? "1 match"
          : `${this.matchIndex + 1} of ${count} matches`
  },
}
