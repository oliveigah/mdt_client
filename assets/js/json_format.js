// Pretty prints JSON text without parsing it into values.
//
// JSON.parse would turn large integers into doubles, drop duplicate keys and
// move integer-like keys to the front of objects, none of which an HTTP client
// should do to a response. This reads the text token by token instead and only
// rewrites the whitespace between tokens, so every number, string and key
// comes out exactly as the server sent it. A sequence of values, as in NDJSON,
// is formatted one value after another.
//
// The output is one string plus the offset of each line in it, which keeps a
// response of millions of lines to a handful of allocations. The work can be
// done in steps, so a large body does not freeze the page while it formats.

const INDENT = "  "
const NUMBER = /^-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?$/

// Parts are joined into chunks now and then, so the list never grows huge.
const CHUNK_PARTS = 65536

// What the formatter accepts next.
const VALUE = 0 // any value
const VALUE_OR_CLOSE = 1 // just after "["
const KEY_OR_CLOSE = 2 // just after "{"
const KEY = 3 // after a "," inside an object
const COLON = 4 // after a key
const AFTER_VALUE = 5 // a "," or a closing bracket, or another top level value

const OPEN_OBJECT = 123 // {
const CLOSE_OBJECT = 125 // }
const OPEN_ARRAY = 91 // [
const CLOSE_ARRAY = 93 // ]
const QUOTE = 34
const BACKSLASH = 92
const COMMA = 44
const COLON_CHAR = 58

const isSpace = (code) => code === 32 || code === 10 || code === 13 || code === 9

const isDelimiter = (code) =>
  isSpace(code) ||
  code === COMMA ||
  code === COLON_CHAR ||
  code === OPEN_OBJECT ||
  code === CLOSE_OBJECT ||
  code === OPEN_ARRAY ||
  code === CLOSE_ARRAY ||
  code === QUOTE

// The index of the quote closing the string that opens at `start`, or -1.
const stringEnd = (source, start) => {
  let from = start + 1

  for (;;) {
    const quote = source.indexOf('"', from)
    if (quote < 0) return -1

    let slashes = 0
    for (let at = quote - 1; at > start && source.charCodeAt(at) === BACKSLASH; at--) slashes++
    if (slashes % 2 === 0) return quote

    from = quote + 1
  }
}

export class JsonFormatter {
  constructor(source) {
    this.source = source
    this.pos = source.charCodeAt(0) === 0xfeff ? 1 : 0
    this.stack = []
    this.state = VALUE
    this.values = 0
    this.done = false
    this.error = null

    this.chunks = []
    this.parts = []
    this.length = 0
    this.lineStart = 0
    this.lineStarts = [0]
    this.maxLength = 0
    this.indents = [""]
    this.text = null
  }

  // How much of the source has been read, from 0 to 1.
  get progress() {
    return this.source.length === 0 ? 1 : this.pos / this.source.length
  }

  get lineCount() {
    return this.lineStarts.length
  }

  // The formatted line at `index`, without its line break.
  line(index) {
    const start = this.lineStarts[index]
    const end = index + 1 < this.lineStarts.length ? this.lineStarts[index + 1] - 1 : this.text.length
    return this.text.slice(start, end)
  }

  // Reads about `budget` more characters, returning true once formatting is
  // over, whether it succeeded or not.
  step(budget = Infinity) {
    if (this.done) return true

    const source = this.source
    const length = source.length
    const stop = Math.min(length, this.pos + budget)
    let at = this.pos

    while (at < stop) {
      const code = source.charCodeAt(at)

      if (isSpace(code)) {
        at++
      } else if (code === QUOTE) {
        const end = stringEnd(source, at)
        if (end < 0) return this.fail("a string is never closed")

        const token = source.slice(at, end + 1)
        if (token.includes("\n")) return this.fail("a string spans lines")

        if (this.state === KEY_OR_CLOSE || this.state === KEY) {
          this.emit(token)
          this.state = COLON
        } else if (!this.scalar(token)) {
          return this.fail("a string is out of place")
        }

        at = end + 1
      } else if (code === OPEN_OBJECT || code === OPEN_ARRAY) {
        if (!this.expectsValue()) return this.fail("a bracket is out of place")

        const close = code === OPEN_OBJECT ? CLOSE_OBJECT : CLOSE_ARRAY
        let next = at + 1
        while (next < length && isSpace(source.charCodeAt(next))) next++

        if (source.charCodeAt(next) === close) {
          this.scalar(code === OPEN_OBJECT ? "{}" : "[]")
          at = next + 1
        } else {
          this.beginValue()
          this.emit(source[at])
          this.stack.push(code)
          this.newline()
          this.emit(this.indent(this.stack.length))
          this.state = code === OPEN_OBJECT ? KEY_OR_CLOSE : VALUE_OR_CLOSE
          at++
        }
      } else if (code === CLOSE_OBJECT || code === CLOSE_ARRAY) {
        const open = code === CLOSE_OBJECT ? OPEN_OBJECT : OPEN_ARRAY
        if (this.state !== AFTER_VALUE || this.stack[this.stack.length - 1] !== open) {
          return this.fail("a bracket is out of place")
        }

        this.stack.pop()
        this.newline()
        this.emit(this.indent(this.stack.length))
        this.emit(source[at])
        this.endValue()
        at++
      } else if (code === COMMA) {
        if (this.state !== AFTER_VALUE || this.stack.length === 0) return this.fail("a comma is out of place")

        this.emit(",")
        this.newline()
        this.emit(this.indent(this.stack.length))
        this.state = this.stack[this.stack.length - 1] === OPEN_OBJECT ? KEY : VALUE
        at++
      } else if (code === COLON_CHAR) {
        if (this.state !== COLON) return this.fail("a colon is out of place")

        this.emit(": ")
        this.state = VALUE
        at++
      } else {
        let end = at + 1
        while (end < length && !isDelimiter(source.charCodeAt(end))) end++

        const word = source.slice(at, end)
        const known = word === "true" || word === "false" || word === "null" || NUMBER.test(word)
        if (!known || !this.scalar(word)) return this.fail(`unexpected ${word.slice(0, 20)}`)

        at = end
      }
    }

    this.pos = at
    return at < length ? false : this.finish()
  }

  // Formats everything in one go.
  run() {
    this.step()
    return this
  }

  expectsValue() {
    return (
      this.state === VALUE ||
      this.state === VALUE_OR_CLOSE ||
      (this.state === AFTER_VALUE && this.stack.length === 0)
    )
  }

  scalar(token) {
    if (!this.expectsValue()) return false

    this.beginValue()
    this.emit(token)
    this.endValue()
    return true
  }

  // Another value at the top level starts on a line of its own.
  beginValue() {
    if (this.stack.length === 0 && this.values > 0) this.newline()
  }

  endValue() {
    if (this.stack.length === 0) this.values++
    this.state = AFTER_VALUE
  }

  indent(depth) {
    return (this.indents[depth] ??= INDENT.repeat(depth))
  }

  emit(text) {
    this.parts.push(text)
    this.length += text.length

    if (this.parts.length >= CHUNK_PARTS) {
      this.chunks.push(this.parts.join(""))
      this.parts = []
    }
  }

  newline() {
    this.maxLength = Math.max(this.maxLength, this.length - this.lineStart)
    this.emit("\n")
    this.lineStart = this.length
    this.lineStarts.push(this.lineStart)
  }

  finish() {
    if (this.stack.length > 0 || this.values === 0 || this.state !== AFTER_VALUE) {
      return this.fail("the body ends early")
    }

    this.maxLength = Math.max(this.maxLength, this.length - this.lineStart)
    this.chunks.push(this.parts.join(""))
    this.text = this.chunks.join("")
    this.chunks = this.parts = null
    this.done = true
    return true
  }

  fail(reason) {
    this.error = reason
    this.chunks = this.parts = null
    this.lineStarts = [0]
    this.text = ""
    this.done = true
    return true
  }
}

// Formats `source` in one go: the formatted text, or null when it is not JSON.
export const formatJson = (source) => {
  const formatter = new JsonFormatter(source).run()
  return formatter.error ? null : formatter.text
}

const HTML_ESCAPES = {"&": "&amp;", "<": "&lt;", ">": "&gt;"}

export const escapeHtml = (text) => text.replace(/[&<>]/g, (char) => HTML_ESCAPES[char])

// Groups: a string, the colon that makes it a key, a number, a literal, a
// bracket, and the remaining punctuation.
const TOKEN = /("(?:[^"\\]|\\.)*")(\s*:)?|(-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)|\b(true|false|null)\b|([{}[\]])|([,:])/g

const span = (tone, text) => `<span class="${tone}">${escapeHtml(text)}</span>`

// Colours one line of JSON as HTML, using the syntax tokens from app.css.
export const highlight = (line) => {
  let html = ""
  let last = 0
  let match

  TOKEN.lastIndex = 0
  while ((match = TOKEN.exec(line)) !== null) {
    if (match.index > last) html += escapeHtml(line.slice(last, match.index))

    const [, string, colon, number, literal, bracket, punct] = match
    if (string !== undefined && colon !== undefined) {
      html += span("text-syn-key", string) + span("text-syn-punct", colon)
    } else if (string !== undefined) {
      html += span("text-syn-string", string)
    } else if (number !== undefined) {
      html += span("text-syn-number", number)
    } else if (literal !== undefined) {
      html += span("text-syn-const", literal)
    } else if (bracket !== undefined) {
      html += span("text-syn-brace", bracket)
    } else {
      html += span("text-syn-punct", punct)
    }

    last = TOKEN.lastIndex
  }

  return html + escapeHtml(line.slice(last))
}
