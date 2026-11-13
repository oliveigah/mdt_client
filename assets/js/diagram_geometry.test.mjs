import assert from "node:assert/strict"
import {test} from "node:test"
import {
  ARROW_GAP,
  LOOP_REACH,
  ROW_STUB,
  anchorAt,
  anchorPoint,
  arrowHead,
  arrowRoute,
  borderPoint,
  bounds,
  distanceToBox,
  distanceToOutline,
  loopBends,
  nearestOutlinePoint,
  outlineNormal,
  outlineSide,
  heightToFit,
  hitTest,
  innerBox,
  leaveBox,
  matchingIds,
  pointAlong,
  polylineDistance,
  portPoint,
  ports,
  resizeBox,
  resolveArrow,
  rowAnchor,
  rowAt,
  rowBox,
  rowIndex,
  searchTerms,
  snapAnchor,
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

test("an arrow attached at both ends to one element, floating, is left as it is", () => {
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

test("ports sit off the middle of each side, pushed out by the gap", () => {
  const rectangle = box("rectangle", 0, 0, 100, 50)
  const offered = ports(rectangle, {x: 50, y: 25})

  assert.deepEqual(offered.map((port) => [port.side, port.row]), [["n", null], ["e", null], ["s", null], ["w", null]])
  assert.deepEqual(offered.map((port) => portPoint(rectangle, port, 10)), [
    {x: 50, y: -10}, {x: 110, y: 25}, {x: 50, y: 60}, {x: -10, y: 25},
  ])
})

test("a table offers ports on its sides, level with the row beside the pointer", () => {
  const users = table()

  // Beside the second row, even from outside the table.
  const beside = ports(users, {x: 230, y: 70})
  assert.deepEqual(beside.map((port) => [port.side, port.row]), [["e", "r2"], ["w", "r2"]])
  assert.deepEqual(beside.map((port) => portPoint(users, port, 10)), [{x: 210, y: 78}, {x: -10, y: 78}])

  // Level with the title, or past the rows, for the table as a whole.
  for (const point of [{x: 100, y: 10}, {x: 100, y: 120}]) {
    const whole = ports(users, point)
    assert.deepEqual(whole.map((port) => port.row), [null, null])
    assert.deepEqual(portPoint(users, whole[0], 10), {x: 210, y: 18})
  }

  // A row gone since falls back to the title.
  assert.deepEqual(portPoint(users, {side: "w", row: "gone"}, 10), {x: -10, y: 18})
})

test("distance to a box is nothing inside it and straight to the nearest side or corner", () => {
  const area = {x: 0, y: 0, width: 100, height: 50}
  assert.equal(distanceToBox(area, {x: 40, y: 20}), 0)
  assert.equal(distanceToBox(area, {x: 112, y: 20}), 12)
  assert.equal(distanceToBox(area, {x: 50, y: -7}), 7)
  assert.equal(distanceToBox(area, {x: -3, y: 54}), 5)
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

const rounded = (values) =>
  Object.fromEntries(Object.entries(values).map(([key, value]) => [key, Math.round(value * 1e6) / 1e6]))

const near = (actual, expected, within = 1e-6) =>
  assert.ok(Math.hypot(actual.x - expected.x, actual.y - expected.y) <= within,
    `${JSON.stringify(actual)} is not ${JSON.stringify(expected)}`)

test("the closest point of an outline is found from inside or out", () => {
  const rectangle = box("rectangle", 0, 0, 200, 100)
  assert.deepEqual(nearestOutlinePoint(rectangle, {x: 150, y: -30}), {x: 150, y: 0})
  assert.deepEqual(nearestOutlinePoint(rectangle, {x: 190, y: 40}), {x: 200, y: 40})
  assert.deepEqual(nearestOutlinePoint(rectangle, {x: 230, y: 130}), {x: 200, y: 100})
  assert.equal(distanceToOutline(rectangle, {x: 100, y: 10}), 10)

  const diamond = box("diamond", 0, 0, 100, 100)
  near(nearestOutlinePoint(diamond, {x: 100, y: 0}), {x: 75, y: 25})

  // Flat, so the closest point is not the one on the way from the middle.
  const ellipse = box("ellipse", 0, 0, 300, 60)
  const spot = nearestOutlinePoint(ellipse, {x: 250, y: -1})
  assert.ok(Math.abs(((spot.x - 150) / 150) ** 2 + ((spot.y - 30) / 30) ** 2 - 1) < 1e-6)
  assert.ok(Math.abs(spot.x - 250) < 15, `ellipse spot ${spot.x}`)
  assert.ok(distanceToOutline(ellipse, {x: 250, y: -1}) < distanceToOutline(ellipse, {x: 250, y: -10}))
})

test("the way out of an outline is square to its side", () => {
  const rectangle = box("rectangle", 0, 0, 200, 100)
  assert.deepEqual(outlineNormal(rectangle, {x: 190, y: 0}), {x: 0, y: -1})
  assert.deepEqual(outlineNormal(rectangle, {x: 200, y: 90}), {x: 1, y: 0})
  assert.equal(outlineSide(rectangle, {x: 10, y: 100}), "s")
  assert.equal(outlineSide(rectangle, {x: 0, y: 50}), "w")

  near(outlineNormal(box("diamond", 0, 0, 100, 100), {x: 75, y: 25}), {x: Math.SQRT1_2, y: -Math.SQRT1_2})
  near(outlineNormal(box("ellipse", 0, 0, 100, 50), {x: 50, y: 50}), {x: 0, y: 1})
})

test("an anchor names a spot of the outline that follows the element as it resizes", () => {
  const rectangle = box("rectangle", 0, 0, 200, 100)
  const anchor = anchorAt(rectangle, -1, {x: 150, y: -12})
  assert.deepEqual(anchor, {x: 0.75, y: 0})
  assert.deepEqual(anchorPoint(rectangle, -1, anchor), {x: 150, y: 0})
  assert.deepEqual(anchorPoint(rectangle, -1, anchor, 6), {x: 150, y: -6})

  const grown = {...rectangle, x: 100, width: 400, height: 300}
  assert.deepEqual(anchorPoint(grown, -1, anchor, 6), {x: 400, y: -6})

  // One written off the outline counts from the closest point on it.
  assert.deepEqual(anchorPoint(rectangle, -1, {x: 0.9, y: 0.5}), {x: 200, y: 50})

  const ellipse = box("ellipse", 0, 0, 100, 100)
  const round = anchorPoint(ellipse, -1, anchorAt(ellipse, -1, {x: 100, y: 0}), 6)
  near(round, {x: 50 + 56 * Math.SQRT1_2, y: 50 - 56 * Math.SQRT1_2}, 1e-2)
})

test("an anchor on a row only picks its side", () => {
  const users = table()
  assert.deepEqual(anchorAt(users, 1, {x: 30, y: 70}), {x: 0, y: 0.5})
  assert.deepEqual(anchorAt(users, 1, {x: 170, y: 70}), {x: 1, y: 0.5})
  assert.deepEqual(anchorPoint(users, 1, {x: 0, y: 0.5}, 6), {x: -6, y: 78})
  assert.deepEqual(anchorPoint(users, 1, {x: 1, y: 0.2}, 6), {x: 206, y: 78})
})

test("anchors near the middle of a side settle on it", () => {
  const rectangle = box("rectangle", 0, 0, 200, 100)
  assert.deepEqual(snapAnchor(rectangle, {x: 0.53, y: 0}, 8), {x: 0.5, y: 0})
  assert.deepEqual(snapAnchor(rectangle, {x: 1, y: 0.45}, 8), {x: 1, y: 0.5})
  assert.deepEqual(snapAnchor(rectangle, {x: 0.6, y: 0}, 8), {x: 0.6, y: 0})
})

test("pinned ends keep their spot, so two arrows into one side need not overlap", () => {
  const source = box("rectangle", 0, 0, 100, 100)
  const target = box("rectangle", 0, 300, 100, 100)
  const elements = new Map([[source.id, source], [target.id, target]])
  const lookup = (id) => elements.get(id)
  const arrow = {type: "arrow", x1: 0, y1: 0, x2: 0, y2: 0, start: source.id, end: target.id}

  assert.deepEqual(resolveArrow(arrow, lookup), {x1: 50, y1: 106, x2: 50, y2: 294})

  // The floating start heads for the pinned end, wherever that is.
  const pinned = resolveArrow({...arrow, endAnchor: {x: 0.25, y: 0}}, lookup)
  const from = borderPoint(source, {x: 25, y: 294}, ARROW_GAP)
  assert.deepEqual(pinned, {x1: from.x, y1: from.y, x2: 25, y2: 294})

  // Pinned at both ends, it runs between the two spots.
  const both = resolveArrow({...arrow, startAnchor: {x: 1, y: 0.5}, endAnchor: {x: 1, y: 0.5}}, lookup)
  assert.deepEqual(both, {x1: 106, y1: 50, x2: 106, y2: 350})

  // An anchor left behind by an end that came loose means nothing.
  const loose = {...arrow, end: null, endAnchor: {x: 0, y: 0}, x2: 500, y2: 500}
  assert.deepEqual(resolveArrow(loose, lookup).x2, 500)
})

test("a floating end heads for the nearest bend rather than the other end", () => {
  const left = box("rectangle", 0, 0, 100, 100)
  const right = box("rectangle", 300, 0, 100, 100)
  const elements = new Map([[left.id, left], [right.id, right]])
  const lookup = (id) => elements.get(id)
  const arrow = {
    type: "arrow", x1: 0, y1: 0, x2: 0, y2: 0, start: left.id, end: right.id,
    points: [{x: 50, y: -100}, {x: 350, y: -100}],
  }

  const ends = rounded(resolveArrow(arrow, lookup))
  assert.deepEqual(ends, {x1: 50, y1: -6, x2: 350, y2: -6})
  assert.deepEqual(arrowRoute({...arrow, ...ends}, lookup), [
    {x: 50, y: -6}, {x: 50, y: -100}, {x: 350, y: -100}, {x: 350, y: -6},
  ])
  assert.deepEqual(bounds({...arrow, ...ends}), {x: 50, y: -100, width: 300, height: 94})
  assert.equal(hitTest({...arrow, ...ends}, {x: 200, y: -101}), true)
  assert.equal(hitTest({...arrow, ...ends}, {x: 200, y: -6}), false)
})

test("a row's run out of the table comes before the bends", () => {
  const users = table()
  const shape = box("rectangle", 500, 300, 100, 100)
  const elements = new Map([[users.id, users], [shape.id, shape]])
  const lookup = (id) => elements.get(id)
  const arrow = {type: "arrow", x1: 0, y1: 0, x2: 0, y2: 0, start: "t", startRow: "r1", end: shape.id, points: [{x: -60, y: 350}]}

  const ends = resolveArrow(arrow, lookup)
  // The bend is to the left, so the row is left from that side.
  assert.deepEqual({x: ends.x1, y: ends.y1}, {x: -6, y: 50})
  assert.deepEqual(arrowRoute({...arrow, ...ends}, lookup).slice(0, 3), [
    {x: -6, y: 50}, {x: -6 - ROW_STUB, y: 50}, {x: -60, y: 350},
  ])
})

test("an element joins itself between two pinned spots", () => {
  const shape = box("rectangle", 0, 0, 100, 100)
  const arrow = {
    type: "arrow", x1: 1, y1: 2, x2: 3, y2: 4, start: shape.id, end: shape.id,
    startAnchor: {x: 0.25, y: 0}, endAnchor: {x: 0.75, y: 0},
  }
  assert.deepEqual(resolveArrow(arrow, () => shape), {x1: 25, y1: -6, x2: 75, y2: -6})

  // Pinned at one end only, there is nothing to tell the other where to go.
  assert.deepEqual(resolveArrow({...arrow, endAnchor: null}, () => shape), {x1: 1, y1: 2, x2: 3, y2: 4})
})

test("a loop runs clear of its element and round the corners the shorter way", () => {
  const shape = box("rectangle", 0, 0, 100, 100)
  const top = (x) => ({point: {x, y: -6}, side: "n"})
  const right = (y) => ({point: {x: 106, y}, side: "e"})
  const out = -LOOP_REACH

  // Both out of the top: up, across, back down.
  assert.deepEqual(loopBends(shape, top(25), top(75)), [{x: 25, y: out}, {x: 75, y: out}])

  // From the top round to the right side: one corner.
  assert.deepEqual(loopBends(shape, top(75), right(25)), [
    {x: 75, y: out}, {x: 100 + LOOP_REACH, y: out}, {x: 100 + LOOP_REACH, y: 25},
  ])

  // From the right side back to the top, the other way round that corner.
  assert.deepEqual(loopBends(shape, right(25), top(75)), [
    {x: 100 + LOOP_REACH, y: 25}, {x: 100 + LOOP_REACH, y: out}, {x: 75, y: out},
  ])

  // Across to the opposite side, round two corners, by the shorter way.
  const bends = loopBends(shape, {point: {x: -6, y: 20}, side: "w"}, right(20))
  assert.deepEqual(bends, [
    {x: out, y: 20}, {x: out, y: out}, {x: 100 + LOOP_REACH, y: out}, {x: 100 + LOOP_REACH, y: 20},
  ])
})

test("a segment leaves a box where it first crosses its edge", () => {
  const area = {x: 0, y: 0, width: 100, height: 40}
  assert.deepEqual(leaveBox(area, {x: 50, y: 20}, {x: 250, y: 20}), {x: 100, y: 20})
  assert.deepEqual(leaveBox(area, {x: 50, y: 20}, {x: 50, y: -80}), {x: 50, y: 0})
  assert.deepEqual(leaveBox(area, {x: 50, y: 20}, {x: 90, y: 30}), null)
})
