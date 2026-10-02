import {
  TEXT_SEARCH,
  WORD_SEARCH,
  addCursors,
  addNextMatch,
  cursorsHtml,
  endOf,
  lineEnds,
  move,
  normalize,
  pastePieces,
  replace,
  selectAllMatches,
  selectWords,
  selectedTexts,
  selection,
  shift,
  startOf,
  typing,
} from "./cursors.js"

// Several carets in a textarea, with VS Code's keys, Cmd for Ctrl on a Mac:
//
//   - Ctrl+D selects the word at the caret, then adds the next match of it
//   - Ctrl+Shift+L selects every match
//   - Alt+Shift+I puts a caret at the end of each line selected
//   - Ctrl+click adds a caret, or takes one away; Ctrl+drag adds a selection
//   - Ctrl+Alt+Up and Down add a caret on the line above or below, and so
//     does Shift+Alt on Linux
//   - Escape, or a click, goes back to one caret
//
// The textarea keeps a selection of its own, the primary, and the others
// are kept here. While there are others, typing, deleting, moving, cutting
// and pasting are done at every one here instead of by the browser, which
// would only do them at its own. Every caret is drawn on `layer`, which
// lies under the textarea and lays its text out alike, the textarea's own
// caret hidden so they all blink together.
//
// What the browser still does at its own caret alone, such as a drop, goes
// back to one caret, and so does an undo: it puts back the text at every
// caret, but only the one selection.
export class MultiCursor {
  constructor(field, layer) {
    this.field = field
    this.layer = layer
    this.value = field.value
    // The selections besides the field's own.
    this.extras = []
    // The column the primary keeps to going up and down, as the field only
    // holds its selection.
    this.goal = null
    // What Ctrl+D searched for last, which goes on while those matches stay
    // selected.
    this.search = null
    // What was copied from several selections, a piece from each.
    this.copied = null
    // Text being composed at the primary, through an input method or a dead
    // key, and put at the others once it is done.
    this.composing = null
    // The cursors before a Ctrl+click, while its mouse button is held.
    this.adding = null
    // An edit made here, being told to LiveView and the undo history.
    this.dispatching = false
    this.drawn = ""
    this.frame = null

    this.listeners = [
      [field, "keydown", (event) => this.keydown(event)],
      [field, "beforeinput", (event) => this.beforeinput(event)],
      [field, "input", () => this.input()],
      [field, "mousedown", (event) => this.mousedown(event)],
      [field, "copy", (event) => this.copy(event)],
      [field, "cut", (event) => this.cut(event)],
      [field, "paste", (event) => this.paste(event)],
      [field, "compositionstart", () => this.compositionstart()],
      [field, "compositionend", (event) => this.compositionend(event)],
      [field, "focus", () => this.draw()],
      [field, "blur", () => this.draw()],
      [document, "selectionchange", () => this.selectionchange()],
      [window, "mouseup", () => this.mouseup()],
    ]
    for (const [target, type, listener] of this.listeners) target.addEventListener(type, listener)
  }

  destroy() {
    for (const [target, type, listener] of this.listeners) target.removeEventListener(type, listener)
    cancelAnimationFrame(this.frame)
  }

  // The field's own selection.
  own() {
    const {selectionStart: start, selectionEnd: end, selectionDirection} = this.field
    return selectionDirection === "backward" ? selection(end, start) : selection(start, end)
  }

  // Every selection, the field's own as the primary.
  cursors() {
    const own = this.own()
    if (this.goal && this.goal.anchor === own.anchor && this.goal.head === own.head) own.goal = this.goal.goal

    return normalize({ranges: [...this.extras, own], primary: this.extras.length})
  }

  // Makes `cursors` the field's: the primary selected in it, the others
  // drawn, and the primary scrolled to.
  set({ranges, primary}) {
    const own = ranges[primary]
    this.extras = ranges.filter((_, index) => index !== primary)
    this.goal = own.goal === undefined ? null : own
    this.field.setSelectionRange(startOf(own), endOf(own), own.head < own.anchor ? "backward" : "forward")
    this.draw()
    this.reveal()
  }

  clear() {
    if (this.extras.length === 0) return
    this.extras = []
    this.composing = null
    this.draw()
  }

  // The value was set from outside, by LiveView.
  refresh() {
    if (this.field.value === this.value) return
    this.value = this.field.value
    this.clear()
  }

  draw() {
    const several = this.extras.length > 0
    // The field's own caret shows while a Ctrl+click is placing it.
    this.field.style.caretColor = several && !this.adding ? "transparent" : ""

    let html = ""
    if (several) {
      const focused = document.activeElement === this.field
      html = this.adding
        ? cursorsHtml(this.field.value, {ranges: this.extras, primary: -1}, {carets: focused})
        : cursorsHtml(this.field.value, this.shown(), {carets: focused})
    }

    if (html !== this.drawn) {
      this.layer.innerHTML = html
      this.drawn = html
    }
  }

  // While text is composed at the primary, the others are where they will
  // be once it is in.
  shown() {
    if (!this.composing) return this.cursors()

    const {length, after} = this.composing
    const extras = shift(this.extras, after, this.field.value.length - length)
    return normalize({ranges: [...extras, this.own()], primary: extras.length})
  }

  // The browser scrolls to its caret only for edits it makes itself.
  reveal() {
    const caret = this.layer.querySelector("[data-primary]")
    if (!caret) return

    const top = caret.offsetTop
    const height = caret.offsetHeight
    const {scrollTop, clientHeight} = this.field
    if (top < scrollTop) {
      this.field.scrollTop = top - height
    } else if (top + height > scrollTop + clientHeight) {
      this.field.scrollTop = top + 2 * height - clientHeight
    }
  }

  // Edits the text at every selection with `change`, as `replace` does,
  // and tells LiveView and the undo history, as the browser would.
  edit(change, inputType, data = null, cursors = this.cursors()) {
    const value = this.field.value
    const result = replace(value, cursors, change)
    if (result.value === value) return

    // The field takes in no more than its maxlength.
    const {maxLength} = this.field
    if (maxLength >= 0 && result.value.length > Math.max(maxLength, value.length)) return

    this.field.setRangeText(result.text, result.from, result.to)
    this.value = result.value
    this.set(result.cursors)

    this.dispatching = true
    try {
      this.field.dispatchEvent(new InputEvent("input", {bubbles: true, inputType, data}))
    } finally {
      this.dispatching = false
    }
  }

  keydown(event) {
    if (event.defaultPrevented || event.isComposing) return

    const command = ctrlOrCmd(event)
    const key = letter(event)
    const value = this.field.value

    if (command && !event.altKey && !event.shiftKey && key === "d") return this.take(event, this.nextMatch())
    if (command && !event.altKey && event.shiftKey && key === "l") return this.take(event, this.allMatches())
    if (!command && event.altKey && event.shiftKey && key === "i") {
      return this.take(event, lineEnds(value, this.cursors()))
    }

    const vertical = event.key === "ArrowUp" ? "up" : event.key === "ArrowDown" ? "down" : null
    if (vertical && event.altKey && (command ? !event.shiftKey : event.shiftKey && !MAC)) {
      return this.take(event, addCursors(value, this.cursors(), vertical))
    }

    if (this.extras.length === 0) return

    if (event.key === "Escape") {
      event.stopPropagation()
      const cursors = this.cursors()
      return this.take(event, {ranges: [cursors.ranges[cursors.primary]], primary: 0})
    }

    const motion = motionOf(event)
    if (motion) return this.take(event, move(value, this.cursors(), motion, event.shiftKey))

    // Left to the field, at its own caret.
    if (event.key === "PageUp" || event.key === "PageDown" || (command && key === "a")) this.clear()
  }

  // A key that is one of these, which sets `cursors` when it gives any.
  take(event, cursors) {
    event.preventDefault()
    if (cursors) this.set(cursors)
  }

  nextMatch() {
    const value = this.field.value
    const cursors = this.cursors()
    const own = cursors.ranges[cursors.primary]
    if (own.anchor === own.head) return this.searched(selectWords(value, cursors), WORD_SEARCH)

    const options = this.searchOptions(cursors)
    return this.searched(addNextMatch(value, cursors, options), options)
  }

  allMatches() {
    const value = this.field.value
    let cursors = this.cursors()
    let options = this.searchOptions(cursors)

    const own = cursors.ranges[cursors.primary]
    if (own.anchor === own.head) {
      cursors = selectWords(value, cursors)
      options = WORD_SEARCH
      if (!cursors) return null
    }

    return this.searched(selectAllMatches(value, cursors, options), options)
  }

  // How to search on from `cursors`: as the last Ctrl+D did, when they are
  // what it left.
  searchOptions(cursors) {
    const search = this.search
    return search && search.value === this.field.value && search.key === keyOf(cursors) ? search.options : TEXT_SEARCH
  }

  searched(cursors, options) {
    if (cursors) this.search = {value: this.field.value, key: keyOf(cursors), options}
    return cursors
  }

  beforeinput(event) {
    if (event.defaultPrevented || this.extras.length === 0) return
    // Composing is the browser's, at its own caret, and is copied to the
    // others once it is done.
    if (event.inputType.includes("Composition")) return

    const change = typing(this.field.value, event.inputType, event.data)
    if (!change) return this.clear()

    event.preventDefault()
    this.edit(change, event.inputType, event.data)
  }

  input() {
    if (this.dispatching) return

    this.value = this.field.value
    if (this.composing) return this.draw()
    // An undo, a redo, or an edit the browser made at its own caret.
    this.clear()
  }

  compositionstart() {
    if (this.extras.length === 0) return
    this.composing = {length: this.field.value.length, after: this.field.selectionEnd}
  }

  // Some webviews put the text composed in only after this event.
  compositionend(event) {
    if (!this.composing) return
    const {data} = event
    setTimeout(() => this.composed(data))
  }

  composed(data) {
    if (!this.composing) return

    const {length, after} = this.composing
    this.composing = null
    this.extras = shift(this.extras, after, this.field.value.length - length)
    if (!data) return this.draw()

    // The primary already has it.
    const cursors = this.cursors()
    this.edit(
      (range, index) =>
        index === cursors.primary
          ? {from: range.head, to: range.head, text: ""}
          : {from: startOf(range), to: endOf(range), text: data},
      "insertCompositionText",
      data,
      cursors,
    )
  }

  // A Ctrl+click lets the field place its caret, or select as the mouse
  // drags, and the caret it had becomes one of the others. Any other click
  // leaves the field its own caret alone.
  mousedown(event) {
    if (event.button !== 0) return

    if (ctrlOrCmd(event) && !event.shiftKey && !event.altKey) {
      this.adding = this.cursors()
      this.extras = this.adding.ranges
      this.draw()
    } else {
      this.clear()
    }
  }

  // A Ctrl+click on a caret takes it away, unless it is the only one.
  mouseup() {
    const before = this.adding
    if (!before) return
    this.adding = null

    const clicked = this.own()
    const hit = startOf(clicked) === endOf(clicked) ? before.ranges.findIndex((range) => range.head === clicked.head) : -1

    if (hit === -1) {
      this.set(normalize({ranges: [...before.ranges, clicked], primary: before.ranges.length}))
    } else if (before.ranges.length === 1) {
      this.set({ranges: [clicked], primary: 0})
    } else {
      const ranges = before.ranges.filter((_, index) => index !== hit)
      const primary = hit === before.primary ? ranges.length - 1 : before.primary - (hit < before.primary ? 1 : 0)
      this.set({ranges, primary})
    }
  }

  // The field's own selection moved some way not handled here.
  selectionchange() {
    if (this.extras.length === 0 || document.activeElement !== this.field) return
    cancelAnimationFrame(this.frame)
    this.frame = requestAnimationFrame(() => this.draw())
  }

  // Copies a piece from each selection, a line each, so pasting at as
  // many carets puts one at each.
  copy(event) {
    if (this.extras.length === 0) return null

    const cursors = this.cursors()
    const pieces = selectedTexts(this.field.value, cursors)
    if (pieces.every((piece) => piece === "")) return null

    event.preventDefault()
    event.clipboardData.setData("text/plain", pieces.join("\n"))
    this.copied = pieces
    return cursors
  }

  cut(event) {
    const cursors = this.copy(event)
    if (!cursors) return

    this.edit((range) => ({from: startOf(range), to: endOf(range), text: ""}), "deleteByCut", null, cursors)
  }

  paste(event) {
    if (this.extras.length === 0) return
    event.preventDefault()

    const text = event.clipboardData.getData("text/plain").replace(/\r\n?/g, "\n")
    const cursors = this.cursors()
    const pieces = pastePieces(text, cursors.ranges.length, this.copied)
    this.edit(
      (range, index) => ({from: startOf(range), to: endOf(range), text: pieces[index]}),
      "insertFromPaste",
      null,
      cursors,
    )
  }
}

const MAC = /Mac|iPhone|iPad/.test(navigator.platform)

const ctrlOrCmd = (event) => event.ctrlKey || event.metaKey

// The letter a key is, by its physical place on layouts without Latin
// letters, or where Alt turns it into another character on a Mac.
const letter = (event) =>
  /^[a-z]$/i.test(event.key) ? event.key.toLowerCase() : event.code?.replace(/^Key/, "").toLowerCase()

const keyOf = ({ranges, primary}) => `${primary}:${ranges.map((range) => `${range.anchor}-${range.head}`).join(",")}`

// Where an arrow key, Home or End takes every caret. Ctrl, or Alt on a
// Mac, goes by words, and Cmd to the ends of lines and of the text.
const motionOf = (event) => {
  const word = event.ctrlKey || event.altKey
  switch (event.key) {
    case "ArrowLeft":
      return event.metaKey ? "lineStart" : word ? "wordLeft" : "left"
    case "ArrowRight":
      return event.metaKey ? "lineEnd" : word ? "wordRight" : "right"
    case "ArrowUp":
      return event.metaKey ? "start" : "up"
    case "ArrowDown":
      return event.metaKey ? "end" : "down"
    case "Home":
      return ctrlOrCmd(event) ? "start" : "lineStart"
    case "End":
      return ctrlOrCmd(event) ? "end" : "lineEnd"
    default:
      return null
  }
}
