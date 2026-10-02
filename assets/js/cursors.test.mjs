import assert from "node:assert/strict"
import {test} from "node:test"
import {
  TEXT_SEARCH,
  WORD_SEARCH,
  addCursors,
  addNextMatch,
  cursorsHtml,
  lineEnds,
  move,
  normalize,
  pastePieces,
  replace,
  selectAllMatches,
  selectWords,
  selectedTexts,
  selection,
  typing,
  wordEnd,
  wordStart,
} from "./cursors.js"

// Text with cursors written in: `|` is a caret, `[text]` a selection made
// forwards and `{text}` one made backwards, and `*` before one marks the
// primary, the last one when none is marked.
const parse = (written) => {
  let value = ""
  let anchor = null
  let marked = false
  let primary = null
  const ranges = []

  for (const char of written) {
    if (char === "*") {
      marked = true
    } else if (char === "|") {
      if (marked) primary = ranges.length
      ranges.push(selection(value.length))
      marked = false
    } else if (char === "[" || char === "{") {
      anchor = value.length
    } else if (char === "]" || char === "}") {
      if (marked) primary = ranges.length
      ranges.push(char === "]" ? selection(anchor, value.length) : selection(value.length, anchor))
      marked = false
    } else {
      value += char
    }
  }

  return {value, cursors: {ranges, primary: primary ?? ranges.length - 1}}
}

const write = (value, {ranges, primary}) => {
  const marks = []
  ranges.forEach(({anchor, head}, index) => {
    const star = index === primary ? "*" : ""
    if (anchor === head) marks.push([head, 1, `${star}|`])
    else if (anchor < head) marks.push([anchor, 0, `${star}[`], [head, 2, "]"])
    else marks.push([head, 0, `${star}{`], [anchor, 2, "}"])
  })
  marks.sort((a, b) => a[0] - b[0] || b[1] - a[1])

  let written = ""
  let last = 0
  for (const [at, , mark] of marks) {
    written += value.slice(last, at) + mark
    last = at
  }
  return written + value.slice(last)
}

const check = (result, expected) => {
  assert.notEqual(result, null)
  assert.equal(write(result.value, result.cursors), expected)
}

// What typing `inputType` does at every cursor in `written`.
const typed = (written, inputType, data = null) => {
  const {value, cursors} = parse(written)
  return replace(value, cursors, typing(value, inputType, data))
}

const moved = (written, motion, extend = false) => {
  const {value, cursors} = parse(written)
  return {value, cursors: move(value, cursors, motion, extend)}
}

const on = (written, fn, ...args) => {
  const {value, cursors} = parse(written)
  const result = fn(value, cursors, ...args)
  return result && {value, cursors: result}
}

test("the notation reads back as written", () => {
  for (const written of ["a|b*|c", "[ab] *{cd}", "*|", "x *[y]"]) {
    const {value, cursors} = parse(written)
    assert.equal(write(value, cursors), written)
  }
})

test("selections that overlap, or meet at a caret, merge", () => {
  // Overlapping selections can't be written, so these are built by hand.
  const merged = (value, ranges, primary) => write(value, normalize({ranges, primary}))

  assert.equal(merged("abc", [selection(2), selection(2)], 1), "ab*|c")
  assert.equal(merged("abcdef", [selection(0, 3), selection(2, 5)], 1), "*[abcde]f")
  // The primary keeps its direction.
  assert.equal(merged("abcd", [selection(3, 1), selection(3)], 0), "a*{bc}d")
  assert.equal(merged("abc", [selection(3), selection(0)], 0), "|abc*|")
  // Two selections side by side stay two, as Ctrl+D on "aa" in "aaaa" makes.
  assert.equal(merged("aaaa", [selection(0, 2), selection(2, 4)], 1), "[aa]*[aa]")
})

test("typing puts the text at every caret and over every selection", () => {
  check(typed("a|b|c*|", "insertText", "X"), "aX|bX|cX*|")
  check(typed("[foo] = *[foo]", "insertText", "bar"), "bar| = bar*|")
  check(typed("one|\ntwo*|", "insertLineBreak"), "one\n|\ntwo\n*|")
})

test("deleting takes a character, or the selection, at each", () => {
  check(typed("ab|cd|ef*|", "deleteContentBackward"), "a|c|e*|")
  check(typed("|ab|cd*|", "deleteContentForward"), "|b|d*|")
  check(typed("[ab]c*[de]", "deleteContentBackward"), "|c*|")
  // The two halves of an emoji go together.
  check(typed("a😀|b😀*|", "deleteContentBackward"), "a|b*|")
  check(typed("|😀a*|😀", "deleteContentForward"), "|a*|")
})

test("deleting from carets in the same word takes the word once", () => {
  check(typed("foo bar|baz*|", "deleteWordBackward"), "foo *|")
  check(typed("|one|two three", "deleteWordForward"), "*| three")
})

test("a delete at the start of the text does nothing there", () => {
  check(typed("|ab*|", "deleteContentBackward"), "|a*|")
})

test("only the edits these cursors make are taken on", () => {
  assert.equal(typing("x", "insertFromDrop", null), null)
  assert.equal(typing("x", "historyUndo", null), null)
  assert.equal(typing("x", "insertText", null), null)
})

test("replace says the one stretch that changed", () => {
  const {value, cursors} = parse("ab|cd|ef")
  const result = replace(value, cursors, typing(value, "insertText", "X"))
  assert.deepEqual({from: result.from, to: result.to, text: result.text}, {from: 2, to: 4, text: "XcdX"})
  assert.equal(value.slice(0, result.from) + result.text + value.slice(result.to), result.value)
})

test("words run over letters, digits and underscores, or over punctuation", () => {
  const value = "let snake_case = a.b  "
  assert.equal(wordEnd(value, 0), 3)
  assert.equal(wordEnd(value, 3), 14)
  assert.equal(wordEnd(value, 14), 16)
  assert.equal(wordStart(value, 14), 4)
  assert.equal(wordStart(value, value.length), 19)
  assert.equal(wordStart("a\nb", 2), 1)
  assert.equal(wordEnd("a\nb", 1), 2)
})

test("arrow keys move every caret, and with Shift select", () => {
  check(moved("a|bc*|d", "right"), "ab|cd*|")
  check(moved("a|bc*|d", "left", true), "{a}b*{c}d")
  check(moved("[ab] *[cd]", "left"), "|ab *|cd")
  check(moved("[ab] *[cd]", "right"), "ab| cd*|")
  check(moved("foo bar| baz*|", "wordLeft"), "foo |bar *|baz")
  check(moved("|a|b*|", "left"), "|a*|b")
})

test("Home goes past the indentation, then to the start; End to the end", () => {
  check(moved("  - one|\n  two*|", "lineStart"), "  |- one\n  *|two")
  check(moved("  |- one\n  *|two", "lineStart"), "|  - one\n*|  two")
  check(moved("|one\n*|two", "lineEnd"), "one|\ntwo*|")
  check(moved("ab|c\nde*|f", "lineEnd", true), "ab[c]\nde*[f]")
})

test("Up and Down keep to their column across a short line", () => {
  const down = moved("abc|def\nx\nabcdef", "down")
  check(down, "abcdef\nx*|\nabcdef")

  const again = {value: down.value, cursors: move(down.value, down.cursors, "down")}
  check(again, "abcdef\nx\nabc*|def")

  check(moved("ab|c\nabc", "up"), "*|abc\nabc")
  check(moved("abc\nab|c", "down"), "abc\nabc*|")
  check(moved("ab|\ncd*|\nef", "down", true), "ab[\ncd]*[\nef]")
})

test("a caret can be added on the line above or below each", () => {
  check(on("ab|c\nabc", addCursors, "down"), "ab|c\nab*|c")
  check(on("a\nab|c", addCursors, "up"), "a*|\nab|c")
  assert.equal(on("ab|c", addCursors, "up"), null)

  // The caret on the short line still keeps to the column it came from.
  const once = on("a\nb\nab|c", addCursors, "up")
  check(once, "a\nb*|\nab|c")
  check({value: once.value, cursors: addCursors(once.value, once.cursors, "up")}, "a*|\nb|\nab|c")
})

test("Ctrl+D on carets selects the word at each", () => {
  check(on("foo|.bar ba*|z", selectWords), "[foo].bar *[baz]")
  assert.equal(on("foo *| bar", selectWords), null)
})

test("Ctrl+D adds the next match of the word, whole and in its case", () => {
  const value = "foo food Foo foo"
  const words = on("[foo] food Foo foo", addNextMatch, WORD_SEARCH)
  check(words, "[foo] food Foo *[foo]")

  const text = on("[foo] food Foo foo", addNextMatch, TEXT_SEARCH)
  check(text, "[foo] *[foo]d Foo foo")
  assert.equal(text.value, value)
})

test("Ctrl+D comes round from the start and stops once all are selected", () => {
  check(on("ab ab *[ab]", addNextMatch, WORD_SEARCH), "*[ab] ab [ab]")
  assert.equal(on("[ab] x *[ab]", addNextMatch, WORD_SEARCH), null)
  // Text that regular expressions would read otherwise is matched as it is.
  check(on("*[a.b] axb a.b", addNextMatch, TEXT_SEARCH), "[a.b] axb *[a.b]")
})

test("Ctrl+Shift+L selects every match, the primary staying put", () => {
  check(on("x foo x *[foo] x foo", selectAllMatches, WORD_SEARCH), "x [foo] x *[foo] x [foo]")
  check(on("*[Ab] ab aB", selectAllMatches, TEXT_SEARCH), "*[Ab] [ab] [aB]")
})

test("Alt+Shift+I puts a caret at the end of each selected line", () => {
  check(on("[one\ntwo\nthree\n]four", lineEnds), "one|\ntwo|\nthree*|\nfour")
  check(on("o[ne\ntw]o", lineEnds), "one|\ntw*|o")
  check(on("[one] and *[two]", lineEnds), "one| and two*|")
  assert.equal(on("one| two", lineEnds), null)
})

test("copying takes a piece from each selection, and pasting spreads them", () => {
  const {value, cursors} = parse("[a]-[bc]-*[d]")
  const pieces = selectedTexts(value, cursors)
  assert.deepEqual(pieces, ["a", "bc", "d"])

  assert.deepEqual(pastePieces("a\nbc\nd", 3, pieces), ["a", "bc", "d"])
  assert.deepEqual(pastePieces("1\n2\n", 2), ["1", "2"])
  assert.deepEqual(pastePieces("1\n2", 3), ["1\n2", "1\n2", "1\n2"])
  assert.deepEqual(pastePieces("same", 2), ["same", "same"])
})

test("the cursors are drawn over the text up to the end of the last one's line", () => {
  const {value, cursors} = parse("a<b [c] *|d\nmore\nrest")
  const html = cursorsHtml(value, cursors)

  assert.match(html, /^a&lt;b <span class="bg-selection">c<\/span><span class="[^"]+"><\/span> <span class="[^"]+" data-primary><\/span>d$/)
  assert.doesNotMatch(cursorsHtml(value, cursors, {carets: false}), /class="[^"]*border/)
})
