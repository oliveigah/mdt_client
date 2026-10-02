import assert from "node:assert/strict"
import {test} from "node:test"
import {highlightMarkdown} from "./markdown_highlight.js"

// The text the highlighted HTML shows, which has to be the source exactly.
const text = (html) =>
  html
    .replace(/<[^>]+>/g, "")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&amp;/g, "&")

// The pieces of `source` painted with `tone`.
const painted = (source, tone) =>
  [...highlightMarkdown(source).matchAll(new RegExp(`<span class="${tone}">([^<]*)</span>`, "g"))].map(
    (match) => text(match[1]),
  )

const SAMPLE = [
  "# Title with `code`",
  "",
  "Some **bold**, *italic*, _under_ and ~~gone~~ text, a snake_case_name.",
  "A [link](https://example.com \"title\") and https://bare.example.com/path.",
  "",
  "- [ ] open task",
  "- [x] done task",
  "  1. nested *item*",
  "",
  "> quoted **words**",
  "",
  "| a | b |",
  "|---|:-:|",
  "| `x` | y |",
  "",
  "```elixir",
  "IO.puts(\"<hi>\") # not a heading",
  "```",
  "",
  "---",
  "[ref]: https://example.com",
  "Escaped \\*stars\\* & <tags>",
  "",
].join("\n")

test("the highlighted text is the source, character for character", () => {
  assert.equal(text(highlightMarkdown(SAMPLE)), SAMPLE)
  assert.equal(highlightMarkdown(SAMPLE).split("\n").length, SAMPLE.split("\n").length)
})

test("headings", () => {
  assert.deepEqual(painted("## A heading", "text-syn-key/55"), ["##"])
  assert.deepEqual(painted("## A heading", "text-syn-key"), [" A heading"])
  assert.deepEqual(painted("#hashtag", "text-syn-key"), [])
})

test("emphasis, strong and strikethrough, but not inside snake_case words", () => {
  assert.deepEqual(painted("**bold** and __bold__", "text-orange"), ["bold", "bold"])
  assert.deepEqual(painted("*one* _two_", "text-violet"), ["one", "two"])
  assert.deepEqual(painted("~~gone~~", "text-muted line-through decoration-faint"), ["gone"])
  assert.deepEqual(painted("a snake_case_name and 2 * 3 * 4", "text-violet"), [])
})

test("inline code keeps what is inside it as written", () => {
  assert.deepEqual(painted("run `mix **test**` now", "text-syn-string"), ["mix **test**"])
  assert.deepEqual(painted("run `mix **test**` now", "text-orange"), [])
})

test("links and bare addresses", () => {
  const source = "[docs](https://hexdocs.pm) and https://elixir-lang.org."
  assert.deepEqual(painted(source, "text-accent"), ["docs"])
  assert.deepEqual(painted(source, "text-faint underline decoration-faint/40"), ["https://hexdocs.pm"])
  assert.deepEqual(painted(source, "text-accent underline decoration-accent/40"), ["https://elixir-lang.org"])
})

test("lists and task boxes, done ones muted", () => {
  assert.deepEqual(painted("- [ ] open\n- [x] closed\n1. first", "text-syn-brace"), ["-", "[ ]", "-", "1."])
  assert.deepEqual(painted("- [x] closed", "text-ok"), ["[x]"])
  assert.deepEqual(painted("- [x] closed", "text-muted"), [" closed"])
})

test("fenced code is code to its closing fence", () => {
  const source = "```js\n# not a heading\n**not bold**\n```\n# heading"
  assert.deepEqual(painted(source, "text-syn-string"), ["# not a heading", "**not bold**"])
  assert.deepEqual(painted(source, "text-teal"), ["js"])
  assert.deepEqual(painted(source, "text-syn-key"), [" heading"])
})

test("a shorter or different fence does not close the block", () => {
  const source = "````\n```\n~~~\n````\ntext"
  assert.deepEqual(painted(source, "text-syn-string"), ["```", "~~~"])
})

test("quotes, rules and tables", () => {
  assert.deepEqual(painted("> quoted", "text-faint"), ["> "])
  assert.deepEqual(painted("---", "text-faint"), ["---"])
  assert.deepEqual(painted("| a | b |\n|---|---|", "text-faint"), ["|", "|", "|", "|---|---|"])
  assert.deepEqual(painted("a | b in prose", "text-faint"), [])
})

test("HTML in the source is shown, not run", () => {
  const html = highlightMarkdown("<script>alert(1)</script> & more")
  assert.ok(!html.includes("<script>"))
  assert.equal(text(html), "<script>alert(1)</script> & more")
})

test("a long note is coloured well within a frame", () => {
  const source = SAMPLE.repeat(Math.ceil(100_000 / SAMPLE.length)).slice(0, 100_000)
  const started = performance.now()
  assert.equal(text(highlightMarkdown(source)), source)
  assert.ok(performance.now() - started < 200)
})
