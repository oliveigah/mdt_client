// A line-at-a-time driver for MDT in headless Chrome, for agents.
//
// Run it through drive.sh. Pipe a script of commands to it, or run it in
// tmux and send one command at a time; `help` lists them. Each command
// prints one line, prefixed with ERROR: when it failed. Piped input exits
// with status 1 if any command failed.

import { createRequire } from "node:module"
import { execSync } from "node:child_process"
import * as fs from "node:fs"
import * as os from "node:os"
import * as path from "node:path"
import * as readline from "node:readline"

const cache = process.env.MDT_DRIVER_CACHE || path.join(os.homedir(), ".cache/mdt-run-driver")
const { chromium } = createRequire(path.join(cache, "package.json"))("playwright-core")

const BASE = process.env.MDT_URL || `http://127.0.0.1:${process.env.PORT || 4100}`
const SHOTS = process.env.SCREENSHOT_DIR || "/tmp/mdt-run/shots"
const TIMEOUT = 15_000
fs.mkdirSync(SHOTS, { recursive: true })

let browser = null
let page = null
let failed = false
const errors = []

// System Chrome first: the browsers Playwright downloads are pinned to one
// playwright-core release, and a cached one is usually for another.
function chromePath() {
  if (process.env.CHROME) return process.env.CHROME

  for (const name of ["google-chrome", "google-chrome-stable", "chromium", "chromium-browser"]) {
    try {
      return execSync(`command -v ${name}`, { encoding: "utf8", shell: "/bin/bash" }).trim()
    } catch {}
  }

  return undefined
}

async function launch(scheme = "dark") {
  if (browser) await browser.close()
  browser = await chromium.launch({ executablePath: chromePath(), args: ["--no-sandbox"] })
  const context = await browser.newContext({ viewport: { width: 1440, height: 900 }, colorScheme: scheme })
  page = await context.newPage()
  page.setDefaultTimeout(TIMEOUT)
  page.on("console", message => message.type() === "error" && errors.push(message.text()))
  page.on("pageerror", error => errors.push(String(error)))
  return `launched (${scheme} system theme, 1440x900)`
}

async function ensurePage() {
  if (!page) console.log(await launch())
  return page
}

// Every page is a LiveView; acting before it connects loses the input.
async function connected() {
  await page.waitForSelector("[data-phx-main].phx-connected")
}

// "\n" and "\t" in typed text become a new line and a tab.
const unescape = text => text.replace(/\\n/g, "\n").replace(/\\t/g, "\t")

const COMMANDS = {
  async launch([scheme]) {
    return launch(scheme === "light" ? "light" : "dark")
  },

  // Signs in, creating the identity if the data directory does not have it.
  async login([username = "demo", password = "demo password"]) {
    await ensurePage()
    await page.goto(BASE + "/")
    await connected()
    await page.fill("#user_username", username)
    await page.fill("#user_password", password)
    await page.click("#sign-in")
    await page.waitForURL("**/tools")
    return `signed in as ${username}`
  },

  async nav([to = "/"]) {
    await ensurePage()
    await page.goto(to.startsWith("http") ? to : BASE + to)
    await connected()
    return `at ${page.url()}`
  },

  async click([selector]) {
    await (await ensurePage()).click(selector)
    return `clicked ${selector}`
  },

  async rclick([selector]) {
    await (await ensurePage()).click(selector, { button: "right" })
    return `right clicked ${selector}`
  },

  async hover([selector]) {
    await (await ensurePage()).hover(selector)
    return `hovering ${selector}`
  },

  async fill(_args, rest) {
    const [selector, text] = splitWord(rest)
    await (await ensurePage()).fill(selector, unescape(text))
    return `filled ${selector}`
  },

  async type(_args, rest) {
    await (await ensurePage()).keyboard.type(unescape(rest))
    return "typed"
  },

  async press([key]) {
    await (await ensurePage()).keyboard.press(key)
    return `pressed ${key}`
  },

  async wait([selector]) {
    await (await ensurePage()).waitForSelector(selector)
    return `found ${selector}`
  },

  // Long enough for MDT's debounced inputs (at most 400ms) to reach the
  // server and the page to be patched.
  async settle([ms = "700"]) {
    await (await ensurePage()).waitForTimeout(Number(ms))
    return `waited ${ms}ms`
  },

  async theme([name]) {
    if (!["system", "light", "dark"].includes(name)) throw new Error("theme system|light|dark")
    await (await ensurePage()).click(`[data-phx-theme=${name}]`)
    await page.waitForTimeout(300)
    return `theme ${name}`
  },

  async ss([name = `shot-${Date.now()}`]) {
    const file = path.join(SHOTS, `${name}.png`)
    await (await ensurePage()).screenshot({ path: file })
    return `screenshot: ${file}`
  },

  async "ss-el"([selector, name = `element-${Date.now()}`]) {
    const file = path.join(SHOTS, `${name}.png`)
    await (await ensurePage()).locator(selector).first().screenshot({ path: file })
    return `screenshot: ${file}`
  },

  async text([selector = "body"]) {
    return (await (await ensurePage()).locator(selector).first().innerText()).trim()
  },

  async count([selector]) {
    return `${await (await ensurePage()).locator(selector).count()} × ${selector}`
  },

  async eval(_args, rest) {
    return JSON.stringify(await (await ensurePage()).evaluate(rest))
  },

  async focused() {
    return JSON.stringify(
      await (await ensurePage()).evaluate(() => {
        const el = document.activeElement
        return el && { tag: el.tagName.toLowerCase(), id: el.id, name: el.name }
      })
    )
  },

  async url() {
    return (await ensurePage()).url()
  },

  async errors() {
    return errors.length ? errors.join("\n") : "no console errors"
  },

  async quit() {
    if (browser) await browser.close()
    process.exit(failed && !process.stdin.isTTY ? 1 : 0)
  },

  async help() {
    return Object.keys(COMMANDS).join(" ")
  },
}

// The first word of `text`, or the first "double quoted" run, which is how a
// selector holding spaces is written, and what follows it.
function splitWord(text) {
  const match = text.match(/^\s*(?:"([^"]*)"|(\S+))\s?/)
  return match ? [match[1] ?? match[2], text.slice(match[0].length)] : ["", ""]
}

function words(text) {
  const found = []
  for (let [word, rest] = splitWord(text); word; [word, rest] = splitWord(rest)) found.push(word)
  return found
}

const rl = readline.createInterface({ input: process.stdin, terminal: false })
const prompt = () => process.stdin.isTTY && process.stdout.write("driver> ")
prompt()

for await (const raw of rl) {
  const line = raw.trim()
  if (line && !line.startsWith("#")) {
    const [command, rest] = splitWord(line)
    const run = COMMANDS[command]

    try {
      if (!run) throw new Error(`unknown command ${command}; try help`)
      console.log(await run(words(rest), rest))
    } catch (error) {
      failed = true
      console.log(`ERROR: ${command}: ${String(error.message || error).split("\n")[0]}`)
    }
  }
  prompt()
}

await COMMANDS.quit()
