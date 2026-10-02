import {escapeHtml} from "./json_format.js"

// Colours Markdown source for the note editor, a line at a time: headings,
// emphasis, code, links, lists, task boxes, quotes, rules and tables, read
// the way comrak renders them in the preview.
//
// What is drawn sits exactly under the text being typed, so only colours
// and lines change here, never a weight, a size or anything else that would
// move a character.

const TONES = {
  mark: "text-faint",
  heading: "text-syn-key",
  headingMark: "text-syn-key/55",
  strong: "text-orange",
  emphasis: "text-violet",
  strike: "text-muted line-through decoration-faint",
  code: "text-syn-string",
  lang: "text-teal",
  link: "text-accent",
  url: "text-faint underline decoration-faint/40",
  bareUrl: "text-accent underline decoration-accent/40",
  list: "text-syn-brace",
  done: "text-ok",
  doneText: "text-muted",
  quote: "text-muted",
}

const paint = (tone, html) => (html === "" ? "" : `<span class="${TONES[tone]}">${html}</span>`)

const mark = (text) => paint("mark", escapeHtml(text))

// The inline syntax, tried at each position in this order. Each part is a
// regular expression of its own, so it reads, and is checked, on its own.
const INLINE_PARTS = [
  // `code`, between runs of as many backticks
  /(?<code>(?<ticks>`+)(?<codeText>.*?[^`])\k<ticks>(?!`))/u,
  // a character taken literally
  /(?<escape>\\[!-\/:-@\[-`{-~])/u,
  // [text](url "title") and ![alt](src)
  /(?<link>(?<open>!?\[)(?<label>[^\]]*)\]\((?<href>[^)\s]*)(?<title>\s+"[^"]*")?\))/u,
  /(?<autolink><(?:https?|ftp|mailto):[^\s<>]+>)/u,
  // a bare address, which comrak links too, less the punctuation after it
  /(?<url>\b(?:https?:\/\/|www\.)[^\s<]*[^\s<?!.,:*_~"')\]])/u,
  // snake_case words, whose underscores are not emphasis
  /(?<word>[\p{L}\p{N}]+(?:_+[\p{L}\p{N}]+)+)/u,
  /(?<strong>(?<strongMark>\*\*|__)(?<strongText>\S(?:.*?\S)?)\k<strongMark>)/u,
  /(?<strike>(?<strikeMark>~~?)(?<strikeText>[^\s~](?:.*?[^\s~])?)\k<strikeMark>(?!~))/u,
  /(?<em>\*(?<emText>[^\s*](?:[^*]*?[^\s*])?)\*)/u,
  /(?<under>_(?<underText>[^\s_](?:[^_]*?[^\s_])?)_(?![\p{L}\p{N}]))/u,
]

const pattern = (parts) => new RegExp(parts.map((part) => part.source).join("|"), "gu")

const INLINE = pattern(INLINE_PARTS)
// In a table row the pipes between cells are syntax too.
const TABLE_INLINE = pattern([...INLINE_PARTS, /(?<pipe>\|)/u])

const token = (groups, text, table) => {
  const {code, escape, link, autolink, url, word, strong, strike, em, under, pipe} = groups

  if (code !== undefined) return mark(groups.ticks) + paint("code", escapeHtml(groups.codeText)) + mark(groups.ticks)
  if (escape !== undefined || pipe !== undefined) return mark(text)
  if (link !== undefined) {
    return (
      mark(groups.open) +
      paint("link", inline(groups.label, table)) +
      mark("](") +
      paint("url", escapeHtml(groups.href)) +
      mark(`${groups.title ?? ""})`)
    )
  }
  if (autolink !== undefined) return mark("<") + paint("bareUrl", escapeHtml(text.slice(1, -1))) + mark(">")
  if (url !== undefined) return paint("bareUrl", escapeHtml(text))
  if (word !== undefined) return escapeHtml(text)
  if (strong !== undefined) return wrapped("strong", groups.strongMark, groups.strongText, table)
  if (strike !== undefined) return wrapped("strike", groups.strikeMark, groups.strikeText, table)
  if (em !== undefined) return wrapped("emphasis", "*", groups.emText, table)
  if (under !== undefined) return wrapped("emphasis", "_", groups.underText, table)
  return escapeHtml(text)
}

const wrapped = (tone, delimiter, text, table) => mark(delimiter) + paint(tone, inline(text, table)) + mark(delimiter)

// matchAll works on a copy of the expression, so the spans nested in a
// match can be read with it while the outer loop goes on.
const inline = (text, table = false) => {
  let html = ""
  let last = 0

  for (const match of text.matchAll(table ? TABLE_INLINE : INLINE)) {
    html += escapeHtml(text.slice(last, match.index)) + token(match.groups, match[0], table)
    last = match.index + match[0].length
  }

  return html + escapeHtml(text.slice(last))
}

const HEADING = /^( {0,3}#{1,6})((?:[ \t].*)?)$/
const SETEXT = /^ {0,3}=+[ \t]*$/
const RULE = /^ {0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*$/
const TABLE_DELIMITER = /^(?=.*\|)(?=.*-)[ \t|:-]+$/
const TABLE_ROW = /^[ \t]*\|/
const QUOTE = /^( {0,3}>[ \t]?)(.*)$/
const LIST = /^([ \t]*)([-*+]|\d{1,9}[.)])([ \t]+|$)(?:(\[[ xX]\])(?=[ \t]|$))?(.*)$/
const DEFINITION = /^( {0,3}\[[^\]]+\]:)([ \t]*)(\S*)(.*)$/

// Fences are matched at any indentation, so code in a list item colours too.
const FENCE = /^([ \t]*)(`{3,}|~{3,})(.*)$/
const CLOSING_FENCE = /^[ \t]*(`{3,}|~{3,})[ \t]*$/

// One line outside a fenced block.
const block = (line) => {
  let match

  if ((match = HEADING.exec(line))) return paint("headingMark", escapeHtml(match[1])) + paint("heading", inline(match[2]))
  if (RULE.test(line)) return mark(line)
  if (SETEXT.test(line)) return paint("headingMark", escapeHtml(line))
  if (TABLE_DELIMITER.test(line)) return mark(line)
  if ((match = QUOTE.exec(line))) return mark(match[1]) + paint("quote", block(match[2]))

  if ((match = LIST.exec(line))) {
    const [, indent, bullet, gap, box, rest] = match
    const done = box !== undefined && box !== "[ ]"
    return (
      escapeHtml(indent) +
      paint("list", escapeHtml(bullet)) +
      gap +
      (box === undefined ? "" : paint(done ? "done" : "list", escapeHtml(box))) +
      (done ? paint("doneText", inline(rest)) : inline(rest))
    )
  }

  if ((match = DEFINITION.exec(line))) {
    const [, label, gap, href, rest] = match
    // A footnote's definition is text, not an address.
    if (label.trimStart().startsWith("[^")) return mark(label) + inline(gap + href + rest)
    return mark(label) + gap + paint("url", escapeHtml(href)) + escapeHtml(rest)
  }

  return inline(line, TABLE_ROW.test(line))
}

// The HTML for `source`, line for line, to sit under a textarea holding it.
export const highlightMarkdown = (source) => {
  const lines = []
  let fence = null

  for (const line of source.split("\n")) {
    if (fence) {
      const closing = CLOSING_FENCE.exec(line)
      if (closing && closing[1][0] === fence[0] && closing[1].length >= fence.length) {
        fence = null
        lines.push(mark(line))
      } else {
        lines.push(paint("code", escapeHtml(line)))
      }
      continue
    }

    const opening = FENCE.exec(line)
    // A backtick fence's info string has no backticks, or it is inline code.
    if (opening && !(opening[2][0] === "`" && opening[3].includes("`"))) {
      fence = opening[2]
      lines.push(escapeHtml(opening[1]) + mark(opening[2]) + paint("lang", escapeHtml(opening[3])))
      continue
    }

    lines.push(block(line))
  }

  return lines.join("\n")
}
