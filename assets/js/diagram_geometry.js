// Geometry and text layout for the diagram editor.
//
// Nothing here touches the DOM, so it runs under `node --test` as well as in
// the browser; the editor hands in whatever measures text. Coordinates are in
// canvas units, the ones elements are stored in, before pan and zoom.

export const SHAPES = ["rectangle", "ellipse", "diamond"]
export const FONT_SIZES = {s: 14, m: 18, l: 26}
export const LINE_HEIGHT = 1.3
// Room between a shape's outline and the text written in it.
export const SHAPE_PADDING = 12
// Room between an attached arrow's tip and the outline it points at.
export const ARROW_GAP = 6
// Tables write smaller than shapes: they hold many short lines.
export const TABLE_FONT_SIZES = {s: 12, m: 14, l: 17}
export const TABLE_CELL_PADDING = 10
// How far a line attached to a row runs straight out of the table before
// heading for its other end, so it reads as leaving that row.
export const ROW_STUB = 18

export const isShape = (element) => SHAPES.includes(element.type)
export const isArrow = (element) => element.type === "arrow"
export const isTable = (element) => element.type === "table"
export const fontSize = (element) => FONT_SIZES[element.size] || FONT_SIZES.m
export const lineHeight = (element) => fontSize(element) * LINE_HEIGHT

export function normalizeRect(a, b) {
  return {
    x: Math.min(a.x, b.x),
    y: Math.min(a.y, b.y),
    width: Math.abs(b.x - a.x),
    height: Math.abs(b.y - a.y),
  }
}

export function bounds(element) {
  if (isArrow(element)) {
    return normalizeRect({x: element.x1, y: element.y1}, {x: element.x2, y: element.y2})
  }
  return {x: element.x, y: element.y, width: element.width, height: element.height}
}

export function center(element) {
  const box = bounds(element)
  return {x: box.x + box.width / 2, y: box.y + box.height / 2}
}

// The box around every element given, or null when there are none.
export function unionBounds(elements) {
  if (elements.length === 0) return null

  let left = Infinity, top = Infinity, right = -Infinity, bottom = -Infinity
  for (const element of elements) {
    const box = bounds(element)
    left = Math.min(left, box.x)
    top = Math.min(top, box.y)
    right = Math.max(right, box.x + box.width)
    bottom = Math.max(bottom, box.y + box.height)
  }
  return {x: left, y: top, width: right - left, height: bottom - top}
}

export function inflate(box, amount) {
  return {
    x: box.x - amount,
    y: box.y - amount,
    width: box.width + amount * 2,
    height: box.height + amount * 2,
  }
}

export function containsPoint(box, point) {
  return point.x >= box.x && point.x <= box.x + box.width &&
    point.y >= box.y && point.y <= box.y + box.height
}

export function containsRect(outer, inner) {
  return inner.x >= outer.x && inner.y >= outer.y &&
    inner.x + inner.width <= outer.x + outer.width &&
    inner.y + inner.height <= outer.y + outer.height
}

// How far `point` is from the box: nothing inside it, and straight to the
// nearest side or corner outside it.
export function distanceToBox(box, point) {
  const dx = Math.max(box.x - point.x, 0, point.x - (box.x + box.width))
  const dy = Math.max(box.y - point.y, 0, point.y - (box.y + box.height))
  return Math.hypot(dx, dy)
}

export function distanceToSegment(point, a, b) {
  const dx = b.x - a.x
  const dy = b.y - a.y
  const lengthSquared = dx * dx + dy * dy
  if (lengthSquared === 0) return Math.hypot(point.x - a.x, point.y - a.y)

  const t = Math.max(0, Math.min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared))
  return Math.hypot(point.x - (a.x + t * dx), point.y - (a.y + t * dy))
}

// Whether `point` lands on the element. A shape counts from anywhere inside
// it, filled or not: picking a box only by its outline is fiddly.
export function hitTest(element, point, tolerance = 0) {
  const {x, y} = center(element)

  switch (element.type) {
    case "arrow":
      return distanceToSegment(point, {x: element.x1, y: element.y1}, {x: element.x2, y: element.y2}) <=
        tolerance + 2

    case "ellipse": {
      const rx = element.width / 2 + tolerance
      const ry = element.height / 2 + tolerance
      if (rx <= 0 || ry <= 0) return false
      return ((point.x - x) / rx) ** 2 + ((point.y - y) / ry) ** 2 <= 1
    }

    case "diamond": {
      const halfWidth = element.width / 2 + tolerance
      const halfHeight = element.height / 2 + tolerance
      if (halfWidth <= 0 || halfHeight <= 0) return false
      return Math.abs(point.x - x) / halfWidth + Math.abs(point.y - y) / halfHeight <= 1
    }

    default:
      return containsPoint(inflate(bounds(element), tolerance), point)
  }
}

// How much of a shape's box its text may use: all of a rectangle, the box
// inscribed in an ellipse, and the one inscribed in a diamond.
const TEXT_AREA = {rectangle: 1, ellipse: Math.SQRT1_2, diamond: 0.5}

// The box the text written in a shape is laid out in.
export function innerBox(element) {
  const ratio = TEXT_AREA[element.type] ?? 1
  const padding = ratio === 1 ? SHAPE_PADDING : SHAPE_PADDING / 2
  const width = element.width * ratio - padding * 2
  const height = element.height * ratio - padding * 2
  const middle = center(element)

  return {
    x: middle.x - Math.max(width, 0) / 2,
    y: middle.y - Math.max(height, 0) / 2,
    width: Math.max(width, 0),
    height: Math.max(height, 0),
  }
}

// The height a shape needs for `textHeight` worth of lines to fit its inner box.
export function heightToFit(element, textHeight) {
  const ratio = TEXT_AREA[element.type] ?? 1
  const padding = ratio === 1 ? SHAPE_PADDING : SHAPE_PADDING / 2
  return (textHeight + padding * 2) / ratio
}

// Where the line from the element's center toward `toward` leaves its
// outline, pushed `gap` further out.
export function borderPoint(element, toward, gap = 0) {
  const origin = center(element)
  const dx = toward.x - origin.x
  const dy = toward.y - origin.y
  const distance = Math.hypot(dx, dy)
  if (distance === 0) return origin

  const halfWidth = Math.max(element.width / 2, 0.5)
  const halfHeight = Math.max(element.height / 2, 0.5)
  let reach

  if (element.type === "ellipse") {
    reach = 1 / Math.sqrt((dx * dx) / (halfWidth * halfWidth) + (dy * dy) / (halfHeight * halfHeight))
  } else if (element.type === "diamond") {
    reach = 1 / (Math.abs(dx) / halfWidth + Math.abs(dy) / halfHeight)
  } else {
    reach = Math.min(
      dx === 0 ? Infinity : halfWidth / Math.abs(dx),
      dy === 0 ? Infinity : halfHeight / Math.abs(dy)
    )
  }

  const scale = reach + gap / distance
  return {x: origin.x + dx * scale, y: origin.y + dy * scale}
}

// Tables: a header holding the title over rows of two cells, the type and
// the name. Their height follows from the rows; `split` is where the name
// column starts, measured from the left edge, laid out by the editor.

export const tableFont = (table) => TABLE_FONT_SIZES[table.size] || TABLE_FONT_SIZES.m
export const tableRowHeight = (table) => Math.round(tableFont(table) * 2)
export const tableHeaderHeight = (table) => Math.round(tableFont(table) * 2.6)
export const tableHeight = (table) =>
  tableHeaderHeight(table) + (table.rows?.length ?? 0) * tableRowHeight(table)

export function rowIndex(table, rowId) {
  if (!rowId || !table || !isTable(table)) return -1
  return table.rows.findIndex((row) => row.id === rowId)
}

export function headerBox(table) {
  return {x: table.x, y: table.y, width: table.width, height: tableHeaderHeight(table)}
}

export function rowBox(table, index) {
  const height = tableRowHeight(table)
  return {x: table.x, y: table.y + tableHeaderHeight(table) + index * height, width: table.width, height}
}

// The row under `point`, or -1 over the header or outside the table.
export function rowAt(table, point) {
  if (point.x < table.x || point.x > table.x + table.width) return -1

  const index = Math.floor((point.y - table.y - tableHeaderHeight(table)) / tableRowHeight(table))
  return index >= 0 && index < table.rows.length ? index : -1
}

// Where a line attached to a row meets the table: the middle of that row, on
// whichever side faces `toward`.
export function rowAnchor(table, index, toward, gap = 0) {
  const box = rowBox(table, index)
  const right = toward.x >= table.x + table.width / 2
  return {x: right ? box.x + box.width + gap : box.x - gap, y: box.y + box.height / 2}
}

// Ports: the spots just outside an element that an arrow can be drawn out
// of, already attached to it. Each side offers one off its middle; a table
// only its left and right, level with the row `point` is beside, which the
// arrow is then attached to, or with the title for the table as a whole.
export function ports(element, point) {
  if (!isTable(element)) return ["n", "e", "s", "w"].map((side) => ({id: element.id, row: null, side}))

  const index = rowAt(element, {x: element.x, y: point.y})
  const row = index >= 0 ? element.rows[index].id : null
  return ["e", "w"].map((side) => ({id: element.id, row, side}))
}

// Where a port sits, `gap` out from the element.
export function portPoint(element, {side, row}, gap) {
  const spot = handlePoints(inflate(bounds(element), gap))[side]
  if (!isTable(element)) return spot

  const index = rowIndex(element, row)
  const line = index >= 0 ? rowBox(element, index) : headerBox(element)
  return {x: spot.x, y: line.y + line.height / 2}
}

// The ends of an arrow, following the elements it is attached to. An end
// attached to a whole element aims at its middle and stops at the outline;
// one attached to a row of a table meets the side of that row. `lookup`
// finds an element by id.
export function resolveArrow(arrow, lookup) {
  const start = arrow.start ? lookup(arrow.start) : null
  const end = arrow.end ? lookup(arrow.end) : null
  const startRow = start ? rowIndex(start, arrow.startRow) : -1
  const endRow = end ? rowIndex(end, arrow.endRow) : -1

  // An element can only be joined to itself from one row to another.
  if (start && start === end && (startRow < 0 || endRow < 0)) {
    return {x1: arrow.x1, y1: arrow.y1, x2: arrow.x2, y2: arrow.y2}
  }

  const aim = (element, row, x, y) => {
    if (!element) return {x, y}
    const middle = center(element)
    return row < 0 ? middle : {x: middle.x, y: rowBox(element, row).y + tableRowHeight(element) / 2}
  }
  const meet = (element, row, toward) =>
    row < 0 ? borderPoint(element, toward, ARROW_GAP) : rowAnchor(element, row, toward, ARROW_GAP)

  const from = aim(start, startRow, arrow.x1, arrow.y1)
  const to = aim(end, endRow, arrow.x2, arrow.y2)
  const a = start ? meet(start, startRow, to) : from
  const b = end ? meet(end, endRow, from) : to

  return {x1: a.x, y1: a.y, x2: b.x, y2: b.y}
}

// The points an arrow is drawn through: its ends, with a short straight run
// out of any row it is attached to. Expects the ends already resolved.
export function arrowRoute(arrow, lookup) {
  const first = {x: arrow.x1, y: arrow.y1}
  const last = {x: arrow.x2, y: arrow.y2}

  const stub = (id, rowId, point) => {
    const table = id ? lookup(id) : null
    if (!table || rowIndex(table, rowId) < 0) return []
    const outward = point.x > table.x + table.width / 2 ? ROW_STUB : -ROW_STUB
    return [{x: point.x + outward, y: point.y}]
  }

  return [first, ...stub(arrow.start, arrow.startRow, first), ...stub(arrow.end, arrow.endRow, last), last]
}

export function polylineDistance(points, point) {
  let nearest = Infinity
  for (let index = 1; index < points.length; index++) {
    nearest = Math.min(nearest, distanceToSegment(point, points[index - 1], points[index]))
  }
  return points.length === 1 ? Math.hypot(point.x - points[0].x, point.y - points[0].y) : nearest
}

// The point `fraction` of the way along a polyline, by length.
export function pointAlong(points, fraction = 0.5) {
  const lengths = points.slice(1).map((point, index) => Math.hypot(point.x - points[index].x, point.y - points[index].y))
  let remaining = lengths.reduce((sum, length) => sum + length, 0) * fraction

  for (let index = 0; index < lengths.length; index++) {
    if (remaining <= lengths[index] && lengths[index] > 0) {
      const t = remaining / lengths[index]
      const a = points[index]
      const b = points[index + 1]
      return {x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t}
    }
    remaining -= lengths[index]
  }
  return points[points.length - 1]
}

// The two barbs of an arrow head at (x2, y2), never longer than half the arrow.
export function arrowHead(x1, y1, x2, y2, size = 14, spread = Math.PI / 7) {
  const angle = Math.atan2(y2 - y1, x2 - x1)
  const length = Math.min(size, Math.hypot(x2 - x1, y2 - y1) / 2)

  return [
    {x: x2 - length * Math.cos(angle - spread), y: y2 - length * Math.sin(angle - spread)},
    {x: x2, y: y2},
    {x: x2 - length * Math.cos(angle + spread), y: y2 - length * Math.sin(angle + spread)},
  ]
}

// Resizes `box` by dragging one of its handles, named by compass point, to
// `point`. The opposite side stays put and the box never turns inside out.
export function resizeBox(box, handle, point, minimum = 8) {
  let left = box.x
  let top = box.y
  let right = box.x + box.width
  let bottom = box.y + box.height

  if (handle.includes("w")) left = Math.min(point.x, right - minimum)
  if (handle.includes("e")) right = Math.max(point.x, left + minimum)
  if (handle.includes("n")) top = Math.min(point.y, bottom - minimum)
  if (handle.includes("s")) bottom = Math.max(point.y, top + minimum)

  return {x: left, y: top, width: right - left, height: bottom - top}
}

// Where each resize handle of a box sits.
export function handlePoints(box) {
  const {x, y, width, height} = box
  const middleX = x + width / 2
  const middleY = y + height / 2

  return {
    nw: {x, y}, n: {x: middleX, y}, ne: {x: x + width, y},
    e: {x: x + width, y: middleY}, se: {x: x + width, y: y + height},
    s: {x: middleX, y: y + height}, sw: {x, y: y + height}, w: {x, y: middleY},
  }
}

// Breaks text into the lines that fit `maxWidth`, as measured by `measure`.
// Line breaks typed by hand are kept; a word too long for a line is split.
// With no width limit, only the typed breaks apply.
export function wrapText(text, maxWidth, measure) {
  const lines = []

  for (const paragraph of text.split("\n")) {
    if (!Number.isFinite(maxWidth)) {
      lines.push(paragraph)
      continue
    }

    let line = ""
    for (const word of paragraph.split(" ")) {
      const candidate = line === "" ? word : `${line} ${word}`

      if (measure(candidate) <= maxWidth) {
        line = candidate
      } else if (measure(word) <= maxWidth) {
        if (line !== "") lines.push(line)
        line = word
      } else {
        if (line !== "") lines.push(line)
        const pieces = breakWord(word, maxWidth, measure)
        lines.push(...pieces.slice(0, -1))
        line = pieces[pieces.length - 1]
      }
    }
    lines.push(line)
  }

  return lines
}

function breakWord(word, maxWidth, measure) {
  const pieces = []
  let piece = ""

  for (const character of word) {
    if (piece !== "" && measure(piece + character) > maxWidth) {
      pieces.push(piece)
      piece = character
    } else {
      piece += character
    }
  }

  pieces.push(piece)
  return pieces
}

// The words of a search, split the way the server splits them.
export function searchTerms(term) {
  return term.toLowerCase().split(/\s+/).filter(Boolean)
}

// Every piece of text an element holds: a table's title and each of its rows.
export function elementTexts(element) {
  if (isTable(element)) {
    return [element.text || "", ...element.rows.map((row) => `${row.type} ${row.name}`)]
  }
  return [element.text || ""]
}

const holds = (text, terms) => {
  const normalized = text.toLowerCase().replace(/\s+/g, " ")
  return terms.some((term) => normalized.includes(term))
}

// The elements whose text holds any of the search words.
export function matchingIds(elements, terms) {
  if (terms.length === 0) return []

  return elements
    .filter((element) => elementTexts(element).some((text) => holds(text, terms)))
    .map((element) => element.id)
}

// Which parts of a table hold any of the search words, so a match can be
// marked on the row it is in.
export function tableMatches(table, terms) {
  return {
    title: holds(table.text || "", terms),
    rows: table.rows.flatMap((row, index) => (holds(`${row.type} ${row.name}`, terms) ? [index] : [])),
  }
}
