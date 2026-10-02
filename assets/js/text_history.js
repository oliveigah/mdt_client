// Undo and redo for every text field in MDT.
//
// The webviews MDT runs in do not agree on undo in a text field: some leave
// Ctrl+Z to the application, Ctrl+Y redoes on few of them, and a value
// LiveView patches in leaves whatever native history there is out of step.
// So what is typed is recorded here, a field at a time, and Ctrl+Z undoes
// while Ctrl+Y or Ctrl+Shift+Z redo (Cmd on a Mac) the same way everywhere.
//
// Typing runs on into one step a word at a time, and so does deleting a
// character at a time; a paste, a cut, a pause or moving the caret starts a
// new one. A field keeps its history while it keeps its id, so a note left
// and opened again still undoes what was typed into it. A value set from
// outside, by LiveView or a script, is where the history starts over: undo
// only ever takes back what was typed.

// A pause in typing longer than this starts a new step.
const GROUP_MS = 1000
// Steps kept for one field, and the characters they may hold between them.
const STEP_LIMIT = 300
const CHAR_LIMIT = 2_000_000
// Fields with an id whose history is kept, the most recently used.
const FIELD_LIMIT = 50

const TEXT_TYPES = new Set(["text", "search", "url", "tel", "email", "password"])

// How an edit groups with the one before it: typing runs on with typing,
// deleting with deleting, and anything else is a step of its own.
export const editKind = (inputType) => {
  switch (inputType) {
    case "insertText":
    case "insertLineBreak":
    case "insertParagraph":
      return "insert"
    case "insertCompositionText":
      return "compose"
    case "deleteContentBackward":
    case "deleteContentForward":
      return "delete"
    default:
      return null
  }
}

// The text replaced to turn `before` into `after`: from `at`, `removed`
// gave way to `inserted`.
export const diff = (before, after) => {
  const shorter = Math.min(before.length, after.length)
  let start = 0
  while (start < shorter && before[start] === after[start]) start++

  let end = 0
  while (end < shorter - start && before[before.length - 1 - end] === after[after.length - 1 - end]) end++

  return {
    at: start,
    removed: before.slice(start, before.length - end),
    inserted: after.slice(start, after.length - end),
  }
}

const sameRange = (a, b) => !!a && !!b && a[0] === b[0] && a[1] === b[1]

const space = (char) => char !== undefined && /\s/.test(char)

const size = (step) => step.removed.length + step.inserted.length

// The history of one field. Selections are `[start, end]`.
export class TextHistory {
  constructor(value = "") {
    this.reset(value)
  }

  reset(value) {
    this.value = value
    this.undoStack = []
    this.redoStack = []
    this.chars = 0
    // The step still open to more typing: its kind, the value it started
    // from, the selection it left and when.
    this.open = null
  }

  // Records an edit that left the field holding `value`. `before` is the
  // selection the edit was made on, or null when it is not known.
  record(value, {kind = null, before = null, after = null, time = 0} = {}) {
    if (value === this.value) return

    const top = this.undoStack[this.undoStack.length - 1]
    const open = this.open

    if (open && top && this.continues(open, {kind, before, after, time, value})) {
      this.chars -= size(top)
      Object.assign(top, diff(open.base, value), {after})
      this.chars += size(top)
      open.after = after
      open.time = time
    } else {
      const change = diff(this.value, value)
      const end = change.at + change.inserted.length
      const step = {
        ...change,
        before: before ?? [change.at, change.at + change.removed.length],
        after: after ?? [end, end],
      }
      this.undoStack.push(step)
      this.chars += size(step)
      this.open = kind && after ? {kind, base: this.value, after, time} : null
    }

    this.value = value
    this.redoStack = []
    this.trim()
  }

  // Whether an edit runs on into the open step: the same kind, soon after,
  // from where the last one left the caret, and not the first space after
  // a word.
  continues(open, {kind, before, after, time, value}) {
    if (!kind || kind !== open.kind || !after || time - open.time > GROUP_MS) return false
    if (kind === "compose") return true
    if (!sameRange(before, open.after) || before[0] !== before[1]) return false
    if (kind !== "insert") return true

    const typed = value.slice(before[0], after[0])
    return !(space(typed[0]) && !space(this.value[before[0] - 1]))
  }

  trim() {
    while (this.undoStack.length > 1 && (this.undoStack.length > STEP_LIMIT || this.chars > CHAR_LIMIT)) {
      this.chars -= size(this.undoStack.shift())
    }
  }

  // Takes back the last step. Says what to replace, and with what, to
  // bring the field back, and where the selection goes.
  undo() {
    const step = this.undoStack.pop()
    if (!step) return null

    this.open = null
    this.chars -= size(step)
    this.redoStack.push(step)
    return this.replace(step.at, step.inserted.length, step.removed, step.before)
  }

  redo() {
    const step = this.redoStack.pop()
    if (!step) return null

    this.open = null
    this.chars += size(step)
    this.undoStack.push(step)
    return this.replace(step.at, step.removed.length, step.inserted, step.after)
  }

  replace(start, length, text, selection) {
    const end = start + length
    this.value = this.value.slice(0, start) + text + this.value.slice(end)
    return {start, end, text, value: this.value, selection}
  }
}

// Ctrl+Z undoes, Ctrl+Y and Ctrl+Shift+Z redo, with Cmd for Ctrl on a Mac.
// The physical key decides on layouts without Latin letters.
export const historyKey = (event) => {
  if (!(event.ctrlKey || event.metaKey) || event.altKey) return null

  const key = /^[a-z]$/i.test(event.key) ? event.key.toLowerCase() : event.code?.replace(/^Key/, "").toLowerCase()
  if (key === "z") return event.shiftKey ? "redo" : "undo"
  if (key === "y" && !event.shiftKey) return "redo"
  return null
}

const historic = (target) =>
  (target instanceof HTMLTextAreaElement ||
    (target instanceof HTMLInputElement && TEXT_TYPES.has(target.type))) &&
  !target.readOnly &&
  !target.disabled

// Email fields, for one, offer no selection.
const selectionOf = (field) => {
  try {
    return field.selectionStart === null ? null : [field.selectionStart, field.selectionEnd]
  } catch {
    return null
  }
}

const byId = new Map()
const byField = new WeakMap()

const historyOf = (field) => {
  if (!field.id) {
    let history = byField.get(field)
    if (!history) byField.set(field, (history = new TextHistory(field.value)))
    return history
  }

  const history = byId.get(field.id) ?? new TextHistory(field.value)
  byId.delete(field.id)
  byId.set(field.id, history)
  if (byId.size > FIELD_LIMIT) byId.delete(byId.keys().next().value)
  return history
}

// The field's history, started over if its value was set from outside
// since it was last typed in.
const currentHistory = (field) => {
  const history = historyOf(field)
  if (history.value !== field.value) history.reset(field.value)
  return history
}

// Starts a field's history over from what it holds now. For a script that
// reuses one field for different texts, which could hold the same value.
export const forgetHistory = (field) => historyOf(field).reset(field.value)

// Listens on `root` for typing in any text field, and for the keys that
// undo and redo it. Undo listens as keys bubble, so a field with an undo of
// its own handles the key first and can claim it with preventDefault.
export const installTextHistory = (root = document) => {
  let pending = null
  let applying = false

  const apply = (field, action) => {
    const history = currentHistory(field)
    const change = action === "undo" ? history.undo() : history.redo()
    if (!change) return

    try {
      field.setRangeText(change.text, change.start, change.end)
      field.setSelectionRange(...change.selection)
    } catch {
      field.value = change.value
    }
    if (field.value !== change.value) field.value = change.value

    // Tells LiveView and the field's hooks, as typing would.
    applying = true
    try {
      field.dispatchEvent(
        new InputEvent("input", {bubbles: true, inputType: action === "undo" ? "historyUndo" : "historyRedo"}),
      )
    } finally {
      applying = false
    }
  }

  root.addEventListener(
    "beforeinput",
    (event) => {
      const field = event.target
      if (!historic(field)) return

      // An undo the webview starts itself, from a menu, takes this path too.
      if (event.inputType === "historyUndo" || event.inputType === "historyRedo") {
        event.preventDefault()
        return apply(field, event.inputType === "historyUndo" ? "undo" : "redo")
      }

      currentHistory(field)
      pending = {field, before: selectionOf(field)}
    },
    true,
  )

  root.addEventListener(
    "input",
    (event) => {
      const field = event.target
      if (applying || !historic(field)) return

      const before = pending?.field === field ? pending.before : null
      pending = null
      historyOf(field).record(field.value, {
        kind: editKind(event.inputType),
        before,
        after: selectionOf(field),
        time: performance.now(),
      })
    },
    true,
  )

  root.addEventListener("keydown", (event) => {
    if (event.defaultPrevented || event.isComposing || !historic(event.target)) return

    const action = historyKey(event)
    if (!action) return

    event.preventDefault()
    apply(event.target, action)
  })
}
