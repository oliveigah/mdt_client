import assert from "node:assert/strict"
import {test} from "node:test"
import {JsonFormatter, formatJson, highlight} from "./json_format.js"

test("formats nested objects and arrays with two space indents", () => {
  assert.equal(
    formatJson(`{"a":1,"b":[true,null,{"c":"d"}],"e":{},"f":[ ]}`),
    [
      "{",
      '  "a": 1,',
      '  "b": [',
      "    true,",
      "    null,",
      "    {",
      '      "c": "d"',
      "    }",
      "  ],",
      '  "e": {},',
      '  "f": []',
      "}",
    ].join("\n"),
  )
})

test("keeps numbers, key order and duplicate keys exactly as sent", () => {
  const source = `{"9":1,"1":2,"id":12345678901234567890,"x":1.50,"y":1e+10,"id":-0}`

  assert.equal(
    formatJson(source),
    [
      "{",
      '  "9": 1,',
      '  "1": 2,',
      '  "id": 12345678901234567890,',
      '  "x": 1.50,',
      '  "y": 1e+10,',
      '  "id": -0',
      "}",
    ].join("\n"),
  )
})

test("leaves strings alone, escapes and brackets inside them included", () => {
  const source = String.raw`["a \"quoted\" {value}, [x]: y", "ends in a slash \\", "é"]`

  assert.equal(
    formatJson(source),
    ["[", String.raw`  "a \"quoted\" {value}, [x]: y",`, String.raw`  "ends in a slash \\",`, String.raw`  "é"`, "]"].join("\n"),
  )
})

test("reformats already indented JSON", () => {
  assert.equal(formatJson('{\n\t"a" :  [ 1 ,\r\n 2 ]\n}\n'), '{\n  "a": [\n    1,\n    2\n  ]\n}')
})

test("formats a sequence of values one after another", () => {
  assert.equal(formatJson('{"a":1}\n{"b":2}\n3'), '{\n  "a": 1\n}\n{\n  "b": 2\n}\n3')
})

test("formats scalars and skips a byte order mark", () => {
  assert.equal(formatJson('﻿"hello"'), '"hello"')
  assert.equal(formatJson("42"), "42")
})

test("rejects what is not JSON", () => {
  for (const source of [
    "",
    "   ",
    "<html></html>",
    "{",
    '{"a":1,}',
    '{"a" 1}',
    "[1 2]",
    '{"a":tru}',
    '["unterminated]',
    "{}}",
    "[1,]",
    '{"a":1}]',
    '"line\nbreak"',
    "01",
  ]) {
    assert.equal(formatJson(source), null, JSON.stringify(source))
  }
})

test("reads lines and their widths without splitting the text", () => {
  const formatter = new JsonFormatter('{"a":[1,2],"long_key":"value"}').run()

  assert.equal(formatter.lineCount, 7)
  assert.equal(formatter.line(0), "{")
  assert.equal(formatter.line(2), "    1,")
  assert.equal(formatter.line(6), "}")
  assert.equal(formatter.maxLength, '  "long_key": "value"'.length)
})

test("formats in steps and reports progress", () => {
  const source = JSON.stringify({items: Array.from({length: 500}, (_, id) => ({id, name: `item ${id}`}))})
  const formatter = new JsonFormatter(source)

  let steps = 0
  while (!formatter.step(1000)) {
    steps++
    assert.ok(formatter.progress > 0 && formatter.progress < 1)
  }

  assert.ok(steps > 5)
  assert.equal(formatter.error, null)
  assert.equal(formatter.text, JSON.stringify(JSON.parse(source), null, 2))
})

test("matches JSON.stringify on a large document", () => {
  const document = {
    users: Array.from({length: 20000}, (_, id) => ({
      id,
      name: `User "${id}"`,
      tags: ["a", "b"],
      active: id % 2 === 0,
      score: id / 7,
      profile: {nested: {deep: [null, {}, []]}},
    })),
  }
  const source = JSON.stringify(document)

  const started = performance.now()
  const formatted = formatJson(source)
  const elapsed = performance.now() - started

  assert.equal(formatted, JSON.stringify(document, null, 2))
  assert.ok(elapsed < 2000, `formatting ${source.length} characters took ${elapsed}ms`)
})

test("highlights keys, strings, numbers, literals and punctuation", () => {
  assert.equal(
    highlight('  "id": 12, "ok": true, "name": "<b>",'),
    '  <span class="text-syn-key">"id"</span><span class="text-syn-punct">:</span> ' +
      '<span class="text-syn-number">12</span><span class="text-syn-punct">,</span> ' +
      '<span class="text-syn-key">"ok"</span><span class="text-syn-punct">:</span> ' +
      '<span class="text-syn-const">true</span><span class="text-syn-punct">,</span> ' +
      '<span class="text-syn-key">"name"</span><span class="text-syn-punct">:</span> ' +
      '<span class="text-syn-string">"&lt;b&gt;"</span><span class="text-syn-punct">,</span>',
  )

  assert.equal(highlight("  ["), '  <span class="text-syn-brace">[</span>')
  assert.equal(highlight("a & b"), "a &amp; b")
})
