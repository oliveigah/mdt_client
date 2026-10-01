---
name: run-mdt
description: Launch MDT's Phoenix dev server with throwaway data and drive it in headless Chrome — sign in, click through a tool, type, switch themes, screenshot. Use when asked to run MDT, start the app, screenshot a tool, or confirm a UI change works in the real app rather than in LiveView tests.
---

MDT is a Phoenix LiveView app that the desktop shell (Tauri) wraps. To see a
change working, run the dev server on its own port with its own data
directory and drive it with `driver.mjs`, a line-at-a-time Playwright REPL.
Paths below are relative to the repository root.

## Start and stop the server

```bash
.claude/skills/run-mdt/server.sh start --fresh   # waits until it serves; --fresh wipes the throwaway data
.claude/skills/run-mdt/server.sh stop
```

It serves `http://127.0.0.1:4100` with data in `/tmp/mdt-run/data` and the
log in `/tmp/mdt-run/server.log`. `PORT` and `MDT_RUN_DIR` override them.
The first start compiles, so it can take a minute.

## Drive it

Pipe a script; screenshots land in `/tmp/mdt-run/shots/`:

```bash
.claude/skills/run-mdt/drive.sh <<'EOF'
login
nav /tools/notes
fill textarea[name=body] # Heading\n\n- [ ] a task
settle
wait "#note-status:has-text('Saved')"
ss notes-dark
theme light
ss notes-light
errors
EOF
```

Then open the screenshots and look at them. To iterate without relaunching
the browser, run it in tmux and send one command at a time:

```bash
tmux new-session -d -s mdt-run -x 200 -y 50
tmux send-keys -t mdt-run '.claude/skills/run-mdt/drive.sh' Enter
timeout 20 bash -c 'until tmux capture-pane -t mdt-run -p | grep -q "driver>"; do sleep 0.2; done'
tmux send-keys -t mdt-run 'login' Enter
tmux capture-pane -t mdt-run -p
```

Each command prints one line, starting `ERROR:` if it failed; a piped
script exits 1 if any did. The first run installs `playwright-core` into
`~/.cache/mdt-run-driver`.

| command | does |
|---|---|
| `login [user] [password]` | signs in, as `demo` / `demo password` by default; a new name creates an identity |
| `nav <path>` | opens a path, such as `/tools/notes`, and waits for the LiveView to connect |
| `click <sel>` / `rclick <sel>` / `hover <sel>` | pointer actions; `rclick` opens the row context menus |
| `fill <sel> <text>` | sets an input's value; `\n` in the text is a new line |
| `type <text>` / `press <key>` | keyboard into whatever has focus |
| `wait <sel>` | waits up to 15s for an element |
| `settle [ms]` | waits 700ms by default, enough for debounced inputs to save |
| `theme system\|light\|dark` | switches the app's theme |
| `ss [name]` / `ss-el <sel> [name]` | screenshot of the page or of one element |
| `text [sel]` / `count <sel>` / `focused` / `url` | reads the page |
| `eval <js>` | evaluates an expression in the page, printed as JSON |
| `launch [light]` | restarts the browser, with a light system theme if asked (dark otherwise) |
| `errors` / `quit` | console errors so far; close |

Selectors are Playwright selectors. Put one that contains spaces in double
quotes: `click "[id^=note-row-]:has-text('Ideas')"`.

## Gotchas

- **Never run `mix phx.server` bare for this.** Its data directory defaults
  to `~/.mdt_client`, which holds the user's real identities, and the
  installed MDT is usually running on port 12995. `server.sh` sets the data
  directory with `elixir --erl '-mdt_client data_dir <<"...">>'`; the value
  must be an Erlang binary, since a charlist breaks string concatenation.
- **Wait for the LiveView before typing.** Filling the sign-in form right
  after the page loaded submitted the password as the username; waiting for
  the LiveView to connect fixed it. `login` and `nav` wait for
  `[data-phx-main].phx-connected`.
- **Inputs are debounced (300–400ms).** `settle` or `wait` for the result
  before you assert on it or take a screenshot.
- **Headless Chrome reports a light system theme.** `drive.sh` launches
  with a dark one; use `theme light|dark` to pin one, or `launch light`.
- **System Chrome over Playwright's browsers.** The cached ms-playwright
  Chromium is pinned to another `playwright-core` release, so the driver uses
  `google-chrome` or `chromium`. Set `CHROME=/path` to choose; `NODE=/path`
  if no `node` is on `PATH`, since `drive.sh` otherwise falls back to the
  one Zed ships.
- **Links can't be followed here.** In the desktop app the opener plugin
  hands `target="_blank"` links to the system browser; headless Chrome just
  opens a tab. Check desktop-only behaviour under `cargo tauri dev`.
