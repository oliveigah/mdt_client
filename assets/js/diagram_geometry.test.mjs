import assert from "node:assert/strict"
import {test} from "node:test"
import {
  ROW_STUB,
  arrowHead,
  arrowRoute,
  borderPoint,
  heightToFit,
  hitTest,
  innerBox,
  matchingIds,
  pointAlong,
  polylineDistance,
  resizeBox,
  resolveArrow,
  rowAnchor,
  rowAt,
  rowBox,
  rowIndex,
  searchTerms,
  tableHeaderHeight,
  tableHeight,
  tableMatches,
  tableRowHeight,
  unionBounds,
  wrapText,
} from "./diagram_geometry.js"

const box = (type, x, y, width, height, extra = {}) => ({id: `${type}-${x}-${y}`, type, x, y, width, height, ...extra})
// Every character is 10 units wide, spaces included.
const measure = (text) => text.length * 10

test("a shape is hit anywhere inside it, filled or not", () => {
  const rectangle = box("rectangle", 0, 0, 100, 50)
  assert.equal(hitTest(rectangle, {x: 50, y: 25}), true)
  assert.equal(hitTest(rectangle, {x: 104, y: 25}), false)
  assert.equal(hitTest(rectangle, {x: 104, y: 25}, 6), true)
})

test("ellipses and diamonds are hit by their outline, not their box", () => {
  const ellipse = box("ellipse", 0, 0, 100, 100)
  assert.equal(hitTest(ellipse, {x: 50, y: 50}), true)
  assert.equal(hitTest(ellipse, {x: 3, y: 3}), false)

  const diamond = box("diamond", 0, 0, 100, 100)
  assert.equal(hitTest(diamond, {x: 50, y: 5}), true)
  assert.equal(hitTest(diamond, {x: 10, y: 10}), false)
})

test("an arrow is hit along its line", () => {
  const arrow = {id: "a", type: "arrow", x1: 0, y1: 0, x2: 100, y2: 0}
  assert.equal(hitTest(arrow, {x: 50, y: 1}), true)
  assert.equal(hitTest(arrow, {x: 50, y: 12}), false)
  assert.equal(hitTest(arrow, {x: 50, y: 12}, 10), true)
})

test("border points land on each outline, pushed out by the gap", () => {
  const rectangle = box("rectangle", 0, 0, 100, 50)
  assert.deepEqual(borderPoint(rectangle, {x: 500, y: 25}), {x: 100, y: 25})
  assert.deepEqual(borderPoint(rectangle, {x: 50, y: -500}, 5), {x: 50, y: -5})

  const ellipse = box("ellipse", 0, 0, 100, 100)
  const point = borderPoint(ellipse, {x: 200, y: 200})
  assert.ok(Math.abs(Math.hypot(point.x - 50, point.y - 50) - 50) < 1e-9)

  const diamond = box("diamond", 0, 0, 100, 100)
  assert.deepEqual(borderPoint(diamond, {x: 50, y: 400}), {x: 50, y: 100})
})

test("an attached arrow runs between the outlines of its elements", () => {
  const left = box("rectangle", 0, 0, 100, 100)
  const right = box("rectangle", 300, 0, 100, 100)
  const elements = new Map([[left.id, left], [right.id, right]])
  const arrow = {type: "arrow", x1: 0, y1: 0, x2: 0, y2: 0, start: left.id, end: right.id}

  assert.deepEqual(resolveArrow(arrow, (id) => elements.get(id)), {x1: 106, y1: 50, x2: 294, y2: 50})
})

test("an arrow with one loose end aims its attached end at that point", () => {
  const shape = box("rectangle", 0, 0, 100, 100)
  const arrow = {type: "arrow", x1: 50, y1: 400, x2: 0, y2: 0, start: null, end: shape.id}

  assert.deepEqual(resolveArrow(arrow, () => shape), {x1: 50, y1: 400, x2: 50, y2: 106})
})

test("an arrow attached at both ends to one element is left as it is", () => {
  const shape = box("rectangle", 0, 0, 100, 100)
  const arrow = {type: "arrow", x1: 1, y1: 2, x2: 3, y2: 4, start: shape.id, end: shape.id}

  assert.deepEqual(resolveArrow(arrow, () => shape), {x1: 1, y1: 2, x2: 3, y2: 4})
})

test("arrow heads point back along the arrow and never outgrow it", () => {
  const [left, tip, right] = arrowHead(0, 0, 100, 0)
  assert.deepEqual(tip, {x: 100, y: 0})
  assert.ok(left.x < 100 && right.x < 100)
  assert.ok(Math.abs(left.y + right.y) < 1e-9)

  const [short] = arrowHead(0, 0, 10, 0)
  assert.ok(Math.hypot(short.x - 10, short.y) <= 5 + 1e-9)
})

test("resizing keeps the opposite side and never turns the box inside out", () => {
  const start = {x: 0, y: 0, width: 100, height: 50}
  assert.deepEqual(resizeBox(start, "se", {x: 150, y: 80}), {x: 0, y: 0, width: 150, height: 80})
  assert.deepEqual(resizeBox(start, "w", {x: 40, y: 999}), {x: 40, y: 0, width: 60, height: 50})
  assert.deepEqual(resizeBox(start, "nw", {x: 500, y: 500}), {x: 92, y: 42, width: 8, height: 8})
})

test("text wraps at words, keeps typed breaks and splits words too long for a line", () => {
  assert.deepEqual(wrapText("one two three", 70, measure), ["one two", "three"])
  assert.deepEqual(wrapText("one\n\ntwo", 1000, measure), ["one", "", "two"])
  assert.deepEqual(wrapText("abcdefghij", 40, measure), ["abcd", "efgh", "ij"])
  assert.deepEqual(wrapText("a b c", Infinity, measure), ["a b c"])
})

test("shapes keep their text inside the outline and grow to fit it", () => {
  const rectangle = box("rectangle", 0, 0, 100, 60)
  assert.deepEqual(innerBox(rectangle), {x: 12, y: 12, width: 76, height: 36})
  assert.equal(heightToFit(rectangle, 36), 60)

  const diamond = box("diamond", 0, 0, 200, 100)
  assert.equal(innerBox(diamond).width, 88)
  assert.equal(heightToFit(diamond, innerBox(diamond).height), 100)
})

test("the bounds of several elements cover arrows by their ends", () => {
  const elements = [
    box("rectangle", 10, 10, 20, 20),
    {id: "a", type: "arrow", x1: 100, y1: 5, x2: 40, y2: 60},
  ]
  assert.deepEqual(unionBounds(elements), {x: 10, y: 5, width: 90, height: 55})
  assert.equal(unionBounds([]), null)
})

test("search terms match any element holding one of the words", () => {
  const elements = [
    {id: "a", text: "Order Service"},
    {id: "b", text: "billing\nqueue"},
    {id: "c", text: ""},
  ]
  const terms = searchTerms("  ORDER   queue ")

  assert.deepEqual(terms, ["order", "queue"])
  assert.deepEqual(matchingIds(elements, terms), ["a", "b"])
  assert.deepEqual(matchingIds(elements, []), [])
})

// A table at the origin: a 36 unit header, then 28 unit rows, at the default size.
const table = (extra = {}) => ({
  id: "t", type: "table", x: 0, y: 0, width: 200, height: 92, split: 60, size: "m", text: "users",
  rows: [{id: "r1", type: "uuid", name: "id"}, {id: "r2", type: "text", name: "email"}],
  ...extra,
})

test("tables are as tall as their header and rows, and know which row is where", () => {
  const users = table()
  assert.equal(tableHeaderHeight(users), 36)
  assert.equal(tableRowHeight(users), 28)
  assert.equal(tableHeight(users), 92)
  assert.equal(tableHeight({...users, rows: []}), 36)

  assert.equal(rowAt(users, {x: 100, y: 20}), -1)
  assert.equal(rowAt(users, {x: 100, y: 40}), 0)
  assert.equal(rowAt(users, {x: 100, y: 70}), 1)
  assert.equal(rowAt(users, {x: 100, y: 95}), -1)
  assert.equal(rowAt(users, {x: 205, y: 40}), -1)
  assert.deepEqual(rowBox(users, 1), {x: 0, y: 64, width: 200, height: 28})
  assert.equal(rowIndex(users, "r2"), 1)
  assert.equal(rowIndex(users, "gone"), -1)
  assert.equal(rowIndex(null, "r2"), -1)
})

test("a line attached to a row leaves from the side of that row facing the other end", () => {
  const users = table()
  assert.deepEqual(rowAnchor(users, 0, {x: 500, y: 0}, 6), {x: 206, y: 50})
  assert.deepEqual(rowAnchor(users, 1, {x: -500, y: 0}, 6), {x: -6, y: 78})
})

test("a relation runs from row to row, with a short run out of each table", () => {
  const users = table()
  const orders = table({id: "o", x: 400, rows: [{id: "o1", type: "uuid", name: "user_id"}]})
  const elements = new Map([[users.id, users], [orders.id, orders]])
  const lookup = (id) => elements.get(id)
  const arrow = {type: "arrow", x1: 0, y1: 0, x2: 0, y2: 0, start: "o", startRow: "o1", end: "t", endRow: "r1"}

  const ends = resolveArrow(arrow, lookup)
  assert.deepEqual(ends, {x1: 394, y1: 50, x2: 206, y2: 50})
  assert.deepEqual(arrowRoute({...arrow, ...ends}, lookup), [
    {x: 394, y: 50}, {x: 394 - ROW_STUB, y: 50}, {x: 206 + ROW_STUB, y: 50}, {x: 206, y: 50},
  ])
})

test("a table can relate one of its rows to another, looping out of one side", () => {
  const users = table()
  const arrow = {type: "arrow", x1: 0, y1: 0, x2: 0, y2: 0, start: "t", startRow: "r2", end: "t", endRow: "r1"}
  const ends = resolveArrow(arrow, () => users)

  assert.deepEqual(ends, {x1: 206, y1: 78, x2: 206, y2: 50})
  assert.deepEqual(arrowRoute({...arrow, ...ends}, () => users).map((point) => point.x), [206, 224, 224, 206])

  // Attached to the table as a whole at both ends, it is left alone.
  const whole = {...arrow, startRow: null, endRow: null, x1: 1, y1: 2, x2: 3, y2: 4}
  assert.deepEqual(resolveArrow(whole, () => users), {x1: 1, y1: 2, x2: 3, y2: 4})
})

test("an end on a row that is gone attaches to the whole table", () => {
  const users = table()
  const arrow = {type: "arrow", x1: 600, y1: 46, x2: 0, y2: 0, start: null, end: "t", endRow: "gone"}

  assert.deepEqual(resolveArrow(arrow, () => users), {x1: 600, y1: 46, x2: 206, y2: 46})
  assert.equal(arrowRoute({...arrow, x2: 206, y2: 46}, () => users).length, 2)
})

test("polylines measure distance and halfway points along every stretch", () => {
  const route = [{x: 0, y: 0}, {x: 100, y: 0}, {x: 100, y: 100}]
  assert.equal(polylineDistance(route, {x: 50, y: 5}), 5)
  assert.equal(polylineDistance(route, {x: 105, y: 50}), 5)
  assert.deepEqual(pointAlong(route), {x: 100, y: 0})
  assert.deepEqual(pointAlong(route, 0.75), {x: 100, y: 50})
})

test("searching a table finds its title and rows, and says which rows", () => {
  const users = table()
  assert.deepEqual(matchingIds([users], ["email"]), ["t"])
  assert.deepEqual(matchingIds([users], ["uuid"]), ["t"])
  assert.deepEqual(tableMatches(users, ["email", "uuid"]), {title: false, rows: [0, 1]})
  assert.deepEqual(tableMatches(users, ["users"]), {title: true, rows: []})
})
