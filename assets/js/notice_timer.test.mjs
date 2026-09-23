import assert from "node:assert/strict"
import {test} from "node:test"
import {NoticeTimer} from "./notice_timer.js"

test("success notice countdown pauses on hover and resumes for the remaining time", () => {
  const original = {
    setTimeout: globalThis.setTimeout,
    clearTimeout: globalThis.clearTimeout,
    performance: globalThis.performance,
    document: globalThis.document,
  }
  let now = 0
  let nextTimer = 0
  let hovered = false
  const timers = new Map()
  const listeners = new Map()
  const events = []
  const el = {
    dataset: {timeout: "6000", noticeId: "42"},
    addEventListener: (name, listener) => listeners.set(name, listener),
    removeEventListener: (name) => listeners.delete(name),
    matches: () => hovered,
    contains: () => false,
  }

  globalThis.setTimeout = (callback, delay) => {
    const id = ++nextTimer
    timers.set(id, {callback, due: now + delay})
    return id
  }
  globalThis.clearTimeout = (id) => timers.delete(id)
  globalThis.performance = {now: () => now}
  globalThis.document = {activeElement: null}

  const advance = (milliseconds) => {
    now += milliseconds
    for (const [id, timer] of timers) {
      if (timer.due <= now) {
        timers.delete(id)
        timer.callback()
      }
    }
  }

  const hook = {el, pushEvent: (name, payload) => events.push({name, payload})}

  try {
    NoticeTimer.mounted.call(hook)
    advance(2000)
    hovered = true
    listeners.get("mouseenter")()
    advance(10000)
    assert.deepEqual(events, [])

    hovered = false
    listeners.get("mouseleave")()
    advance(3999)
    assert.deepEqual(events, [])
    advance(1)
    assert.deepEqual(events, [{name: "dismiss_notice", payload: {id: "42"}}])

    NoticeTimer.destroyed.call(hook)
    assert.equal(listeners.size, 0)
  } finally {
    globalThis.setTimeout = original.setTimeout
    globalThis.clearTimeout = original.clearTimeout
    globalThis.performance = original.performance
    globalThis.document = original.document
  }
})
