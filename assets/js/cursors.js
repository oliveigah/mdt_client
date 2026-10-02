import {escapeHtml} from "./json_format.js"

// Several selections in one text field, as VS Code has them, worked out on
// the text alone: what typing, deleting and moving do at each of them, and
// the ones Ctrl+D, Ctrl+Shift+L, Alt+Shift+I and adding a caret above or
// below make. multi_cursor.js puts them on a textarea.
//
// A selection is `{anchor, head}`: it holds the text between the two, and
// its caret is at the head. Cursors are `{ranges, primary}`, the selections
// in order with none overlapping, and the index of the field's own.

export const selection = (anchor, head = anchor) => ({anchor, head})
export const startOf = (range) => Math.min(range.anchor, range.head)
export const endOf = (range) => Math.max(range.anchor, range.head)
const collapsed = (range) => range.anchor === range.head

// Puts the selections in order and merges the ones that overlap, or that
// meet where one of them is only a caret. The primary is the one its own
// ends up in, which keeps its direction.
export const normalize = ({ranges, primary}) => {
  const order = ranges
    .map((range, index) => ({range, primary: index === primary}))
    .sort((a, b) => startOf(a.range) - startOf(b.range) || endOf(a.range) - endOf(b.range))

  const merged = []
  for (const item of order) {
    const last = merged[merged.length - 1]
    const meets =
      last &&
      (collapsed(last.range) || collapsed(item.range)
        ? startOf(item.range) <= endOf(last.range)
        : startOf(item.range) < endOf(last.range))

    if (!meets) {
      merged.push(item)
      continue
    }

    const from = startOf(last.range)
    const to = Math.max(endOf(last.range), endOf(item.range))
    const kept = item.primary || !last.primary ? item.range : last.range
    last.range = kept.head < kept.anchor ? selection(to, from) : selection(from, to)
    last.primary ||= item.primary
  }

  return {
    ranges: merged.map((item) => item.range),
    primary: Math.max(0, merged.findIndex((item) => item.primary)),
  }
}

// Edits the text at every selection at once. `change` gives, for each
// selection and its index, the stretch of text to replace, `from` and `to`
// — the selection itself, or for a caret what a delete reaches — and the
// `text` to put there. Stretches that overlap, as deleting a word from two
// carets in it does, become one. Each caret ends up after what was put in
// for it.
//
// Says the new value and cursors, and the one stretch of the old value
// that changed, from the first edit to the last, with the text that
// replaces it.
export const replace = (value, {ranges, primary}, change) => {
  const edits = []
  ranges.forEach((range, index) => {
    let edit = {...change(range, index), owners: [index]}
    while (edits.length && edit.from < edits[edits.length - 1].to) {
      const last = edits.pop()
      edit = {
        from: Math.min(last.from, edit.from),
        to: Math.max(last.to, edit.to),
        text: last.text + edit.text,
        owners: [...last.owners, ...edit.owners],
      }
    }
    edits.push(edit)
  })

  let text = ""
  let last = 0
  let shift = 0
  const carets = []
  for (const edit of edits) {
    text += value.slice(last, edit.from) + edit.text
    for (const owner of edit.owners) carets[owner] = selection(edit.from + shift + edit.text.length)
    shift += edit.text.length - (edit.to - edit.from)
    last = edit.to
  }
  text += value.slice(last)

  const from = edits[0].from
  const to = edits[edits.length - 1].to
  return {
    value: text,
    cursors: normalize({ranges: carets, primary}),
    from,
    to,
    text: text.slice(from, to + shift),
  }
}

// Where each kind of edit the browser reports, as a `beforeinput`, reaches
// from a caret; a selection is replaced whole.
const REACH = {
  deleteContentBackward: (value, at) => charBefore(value, at),
  deleteContentForward: (value, at) => charAfter(value, at),
  deleteWordBackward: (value, at) => wordStart(value, at),
  deleteWordForward: (value, at) => wordEnd(value, at),
  deleteSoftLineBackward: (value, at) => lineStart(value, at),
  deleteHardLineBackward: (value, at) => lineStart(value, at),
  deleteSoftLineForward: (value, at) => lineEnd(value, at),
  deleteHardLineForward: (value, at) => lineEnd(value, at),
}

// The change, for `replace`, that the edit `inputType` makes at each
// selection, or null for an edit these cursors do not make.
export const typing = (value, inputType, data) => {
  const put = (text) => (range) => ({from: startOf(range), to: endOf(range), text})

  switch (inputType) {
    case "insertText":
      return data == null ? null : put(data)
    case "insertLineBreak":
    case "insertParagraph":
      return put("\n")
  }

  const reach = REACH[inputType]
  if (!reach) return null

  return (range) => {
    if (!collapsed(range)) return {from: startOf(range), to: endOf(range), text: ""}
    const to = reach(value, range.head)
    return {from: Math.min(range.head, to), to: Math.max(range.head, to), text: ""}
  }
}

const high = (code) => code >= 0xd800 && code <= 0xdbff
const low = (code) => code >= 0xdc00 && code <= 0xdfff

// A character either side of `at`, the two halves of one past the Basic
// Multilingual Plane, such as an emoji, taken together.
export const charBefore = (value, at) =>
  at > 1 && low(value.charCodeAt(at - 1)) && high(value.charCodeAt(at - 2)) ? at - 2 : Math.max(0, at - 1)

export const charAfter = (value, at) =>
  high(value.charCodeAt(at)) && low(value.charCodeAt(at + 1)) ? at + 2 : Math.min(value.length, at + 1)

export const lineStart = (value, at) => (at === 0 ? 0 : value.lastIndexOf("\n", at - 1) + 1)

export const lineEnd = (value, at) => {
  const end = value.indexOf("\n", at)
  return end === -1 ? value.length : end
}

const WORD = /[\p{L}\p{N}_]/u
const BLANK = /[ \t]/

const kind = (char) => (WORD.test(char) ? "word" : BLANK.test(char) ? "blank" : "mark")

// Where Ctrl+Left goes: back over blanks, then over a word or a run of
// punctuation; from the start of a line, to the end of the one before.
export const wordStart = (value, at) => {
  if (value[at - 1] === "\n") return at - 1

  let i = at
  while (i > 0 && BLANK.test(value[i - 1])) i--
  if (i === 0 || value[i - 1] === "\n") return i

  const run = kind(value[i - 1])
  while (i > 0 && value[i - 1] !== "\n" && kind(value[i - 1]) === run) i--
  return i
}

// Where Ctrl+Right goes, the same way forward.
export const wordEnd = (value, at) => {
  if (value[at] === "\n") return at + 1

  let i = at
  while (i < value.length && BLANK.test(value[i])) i++
  if (i === value.length || value[i] === "\n") return i

  const run = kind(value[i])
  while (i < value.length && value[i] !== "\n" && kind(value[i]) === run) i++
  return i
}

// The word `at` is in or just after, or null where there is none.
export const wordAt = (value, at) => {
  let from = at
  let to = at
  while (from > 0 && WORD.test(value[from - 1])) from--
  while (to < value.length && WORD.test(value[to])) to++
  return from === to ? null : {from, to}
}

// Home goes to the first character of the line past its indentation, or
// from there to the very start.
const home = (value, at) => {
  const start = lineStart(value, at)
  const end = lineEnd(value, at)
  let text = start
  while (text < end && BLANK.test(value[text])) text++
  return at === text ? start : text
}

const MOTIONS = {
  left: charBefore,
  right: charAfter,
  wordLeft: wordStart,
  wordRight: wordEnd,
  lineStart: home,
  lineEnd,
  start: () => 0,
  end: (value) => value.length,
}

// Up and Down keep to the column a caret set out from, `goal`, across
// lines too short to reach it. Lines are the text's own, not where the
// field wraps them. Null past the first line or the last.
const vertical = (value, range, motion, extend) => {
  const from = extend || collapsed(range) ? range.head : motion === "up" ? startOf(range) : endOf(range)
  const line = lineStart(value, from)
  const goal = range.goal ?? from - line

  let head
  if (motion === "up") {
    if (line === 0) return null
    head = Math.min(lineStart(value, line - 1) + goal, line - 1)
  } else {
    const end = lineEnd(value, from)
    if (end === value.length) return null
    head = Math.min(end + 1 + goal, lineEnd(value, end + 1))
  }

  return {...(extend ? selection(range.anchor, head) : selection(head)), goal}
}

// Moves every caret as an arrow key, Home or End would; extending, only
// the heads move, so each selection grows or shrinks. Up from the first
// line goes to the start, and down from the last to the end.
export const move = (value, {ranges, primary}, motion, extend = false) => {
  const moved = ranges.map((range) => {
    if (motion === "up" || motion === "down") {
      const edge = motion === "up" ? 0 : value.length
      return vertical(value, range, motion, extend) ?? (extend ? selection(range.anchor, edge) : selection(edge))
    }

    if (!extend && !collapsed(range) && (motion === "left" || motion === "right")) {
      return selection(motion === "left" ? startOf(range) : endOf(range))
    }

    const head = MOTIONS[motion](value, range.head)
    return extend ? selection(range.anchor, head) : selection(head)
  })

  return normalize({ranges: moved, primary})
}

// A caret more on the line above, or below, each one, in the column it
// keeps to. The one added for the primary becomes the primary. Null when
// there is no line to add any on.
export const addCursors = (value, {ranges, primary}, motion) => {
  const added = ranges.map((range) => vertical(value, {...selection(range.head), goal: range.goal}, motion, false))
  if (!added[primary]) return null

  return normalize({
    ranges: [...ranges, ...added.filter(Boolean)],
    primary: ranges.length + added.slice(0, primary).filter(Boolean).length,
  })
}

// Ctrl+D on a caret selects the word at it, and at every other caret too.
// The matches added after are that word, whole and in the same case; after
// a selection made some other way, they are its text in any case, as in
// VS Code.
export const WORD_SEARCH = {wholeWord: true, matchCase: true}
export const TEXT_SEARCH = {wholeWord: false, matchCase: false}

// Null when the primary is not at a word.
export const selectWords = (value, {ranges, primary}) => {
  if (!wordAt(value, ranges[primary].head)) return null

  return normalize({
    ranges: ranges.map((range) => {
      const word = collapsed(range) && wordAt(value, range.head)
      return word ? selection(word.from, word.to) : range
    }),
    primary,
  })
}

const pattern = (text, {wholeWord, matchCase}) => {
  const escaped = text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
  const source = wholeWord ? `(?<![\\p{L}\\p{N}_])${escaped}(?![\\p{L}\\p{N}_])` : escaped
  return new RegExp(source, matchCase ? "gu" : "giu")
}

const selectedText = (value, range) => value.slice(startOf(range), endOf(range))

// The next match of the primary's text after it, coming round from the
// start, added as the new primary. Null when there is none not yet
// selected.
export const addNextMatch = (value, {ranges, primary}, options) => {
  const current = ranges[primary]
  const text = selectedText(value, current)
  if (text === "") return null

  const search = pattern(text, options)
  const free = (from, to) => !ranges.some((range) => startOf(range) < to && from < endOf(range))

  let from = endOf(current)
  let wrapped = false
  for (;;) {
    search.lastIndex = from
    const match = search.exec(value)

    if (!match || (wrapped && match.index >= startOf(current))) {
      if (wrapped) return null
      wrapped = true
      from = 0
      continue
    }

    const end = match.index + match[0].length
    if (free(match.index, end)) {
      return normalize({ranges: [...ranges, selection(match.index, end)], primary: ranges.length})
    }
    from = end
  }
}

// Every match of the primary's text, the primary staying where it was.
export const selectAllMatches = (value, {ranges, primary}, options) => {
  const current = ranges[primary]
  const text = selectedText(value, current)
  if (text === "") return null

  const found = [...value.matchAll(pattern(text, options))].map((match) =>
    selection(match.index, match.index + match[0].length),
  )

  return normalize({
    ranges: found,
    primary: Math.max(0, found.findIndex((range) => range.anchor === startOf(current))),
  })
}

// Alt+Shift+I: a caret at the end of each line a selection takes in, the
// last where the selection ends, unless that is the very start of its
// line. Carets give none, so null when there are only carets.
export const lineEnds = (value, {ranges}) => {
  const carets = []

  for (const range of ranges) {
    const from = startOf(range)
    const to = endOf(range)
    if (from === to) continue

    for (let end = value.indexOf("\n", from); end !== -1 && end < to; end = value.indexOf("\n", end + 1)) {
      carets.push(selection(end))
    }
    if (to > lineStart(value, to)) carets.push(selection(to))
  }

  return carets.length === 0 ? null : normalize({ranges: carets, primary: carets.length - 1})
}

// The text of each selection, for the clipboard.
export const selectedTexts = (value, {ranges}) => ranges.map((range) => selectedText(value, range))

// What a paste puts at each of `count` selections: the pieces copied from
// as many, a line each when the text has as many lines, or else the whole
// text at every one.
export const pastePieces = (text, count, copied = null) => {
  if (copied && copied.length === count && copied.join("\n") === text) return copied

  const lines = (text.endsWith("\n") ? text.slice(0, -1) : text).split("\n")
  return count > 1 && lines.length === count ? lines : Array(count).fill(text)
}

// Moves the selections past `at` by `delta`, as text put in or taken out
// there does.
export const shift = (ranges, at, delta) => {
  const moved = (offset) => (offset >= at ? offset + delta : offset)
  return ranges.map((range) => selection(moved(range.anchor), moved(range.head)))
}

const CARET = "animate-caret-blink -mr-px border-l border-accent"
const SELECTED = "bg-selection"

// The cursors as HTML, to lay over the field: its text up to the end of
// the line of the last of them, which wraps as the field does, and is
// left transparent, with every selection but the primary shaded — the
// field shades its own — and, when `carets`, every caret drawn. The
// primary's caret is marked `data-primary` either way, so it can be found.
export const cursorsHtml = (value, {ranges, primary}, {carets = true} = {}) => {
  let html = ""
  let last = 0
  const text = (to) => {
    html += escapeHtml(value.slice(last, to))
    last = to
  }

  ranges.forEach((range, index) => {
    const from = startOf(range)
    const to = endOf(range)
    const caret = `<span${carets ? ` class="${CARET}"` : ""}${index === primary ? " data-primary" : ""}></span>`

    text(from)
    if (range.head === from) html += caret
    if (to === from) return

    if (index === primary) {
      text(to)
    } else {
      html += `<span class="${SELECTED}">${escapeHtml(value.slice(from, to))}</span>`
      last = to
    }
    if (range.head === to) html += caret
  })

  text(lineEnd(value, last))
  return html
}
