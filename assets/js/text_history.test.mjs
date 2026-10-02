import assert from "node:assert/strict"
import {test} from "node:test"
import {TextHistory, diff, editKind, historyKey} from "./text_history.js"

// Types `text` one character at a time at the caret, as the browser would
// report it, `gap` milliseconds apart.
const type = (history, text, {at = history.value.length, time = 0, gap = 10} = {}) => {
  let caret = at
  for (const char of text) {
    const value = history.value.slice(0, caret) + char + history.value.slice(caret)
    history.record(value, {
      kind: editKind(char === "\n" ? "insertLineBreak" : "insertText"),
      before: [caret, caret],
      after: [caret + 1, caret + 1],
      time,
    })
    caret++
    time += gap
  }
  return time
}

const backspace = (history, count, {time = 0} = {}) => {
  let caret = history.value.length
  for (let i = 0; i < count; i++) {
    history.record(history.value.slice(0, caret - 1) + history.value.slice(caret), {
      kind: editKind("deleteContentBackward"),
      before: [caret, caret],
      after: [caret - 1, caret - 1],
      time: time + i * 10,
    })
    caret--
  }
}

test("diff finds the text replaced between two values", () => {
  assert.deepEqual(diff("hello world", "hello brave world"), {at: 6, removed: "", inserted: "brave "})
  assert.deepEqual(diff("abc", "aXc"), {at: 1, removed: "b", inserted: "X"})
  assert.deepEqual(diff("same", "same"), {at: 4, removed: "", inserted: ""})
  assert.deepEqual(diff("", "new"), {at: 0, removed: "", inserted: "new"})
})

test("typing undoes a word at a time and redoes it back", () => {
  const history = new TextHistory("")
  type(history, "hello brave world")

  const steps = []
  let change
  while ((change = history.undo())) steps.push(change.value)
  assert.deepEqual(steps, ["hello brave", "hello", ""])

  assert.equal(history.redo().value, "hello")
  assert.equal(history.redo().value, "hello brave")
  assert.equal(history.redo().value, "hello brave world")
  assert.equal(history.redo(), null)
})

test("undo says what to replace and where the caret goes", () => {
  const history = new TextHistory("ab")
  type(history, "XY", {at: 1})

  assert.deepEqual(history.undo(), {start: 1, end: 3, text: "", value: "ab", selection: [1, 1]})
  assert.deepEqual(history.redo(), {start: 1, end: 1, text: "XY", value: "aXYb", selection: [3, 3]})
})

test("a pause, a jump of the caret or a new kind of edit starts a new step", () => {
  const paused = new TextHistory("")
  const time = type(paused, "ab")
  type(paused, "cd", {time: time + 5000})
  assert.equal(paused.undo().value, "ab")

  const moved = new TextHistory("")
  type(moved, "abcd")
  type(moved, "X", {at: 1})
  assert.equal(moved.undo().value, "abcd")

  const mixed = new TextHistory("")
  type(mixed, "abcd")
  backspace(mixed, 2, {time: 100})
  assert.equal(mixed.undo().value, "abcd")
  assert.equal(mixed.undo().value, "")
})

test("deleting a character at a time is one step", () => {
  const history = new TextHistory("")
  type(history, "word")
  backspace(history, 3, {time: 100})
  assert.equal(history.value, "w")
  assert.equal(history.undo().value, "word")
})

test("a paste is a step of its own", () => {
  const history = new TextHistory("")
  type(history, "ab")
  history.record("abPASTED", {kind: editKind("insertFromPaste"), before: [2, 2], after: [8, 8], time: 30})
  type(history, "cd", {time: 40})

  assert.equal(history.undo().value, "abPASTED")
  assert.equal(history.undo().value, "ab")
})

test("a line break ends the word before it", () => {
  const history = new TextHistory("")
  type(history, "first\nsecond")
  assert.equal(history.undo().value, "first")
})

test("a new edit clears what could be redone", () => {
  const history = new TextHistory("")
  type(history, "one two")
  history.undo()
  type(history, "!", {time: 1000})
  assert.equal(history.redo(), null)
})

test("an edit whose selection is not known is still undone", () => {
  const history = new TextHistory("abc")
  history.record("aZc", {})
  const change = history.undo()
  assert.equal(change.value, "abc")
  assert.deepEqual(change.selection, [1, 2])
})

test("keys: Ctrl+Z undoes, Ctrl+Y and Ctrl+Shift+Z redo, Cmd too", () => {
  const key = (overrides) => historyKey({ctrlKey: false, metaKey: false, altKey: false, shiftKey: false, ...overrides})

  assert.equal(key({key: "z", ctrlKey: true}), "undo")
  assert.equal(key({key: "Z", ctrlKey: true, shiftKey: true}), "redo")
  assert.equal(key({key: "y", ctrlKey: true}), "redo")
  assert.equal(key({key: "z", metaKey: true}), "undo")
  assert.equal(key({key: "z"}), null)
  assert.equal(key({key: "z", ctrlKey: true, altKey: true}), null)
  assert.equal(key({key: "c", ctrlKey: true}), null)
  // A Cyrillic layout reports the letter typed; the key is still Z.
  assert.equal(key({key: "я", code: "KeyZ", ctrlKey: true}), "undo")
})
