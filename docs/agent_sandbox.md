# Agent Sandbox

Status (2026-11-12): the first slice is built and was tried live with a real
VM: the image build, the VM's lifecycle, the egress proxy (tunnels, TLS
interception, placeholder swaps, approvals), credential and network grants
with values in the vault, and every screen. Not built yet: the agent channel
(agents asking for grants), host commands, export, and the live VPN check.
See [Built so far](#built-so-far) and [Next](#next).

Built and tried live (2026-11-12): the image and the VM's state. See
[Image and VM state](#image-and-vm-state).

## What it is for

LLM agents run inside a microsandbox VM. MDT starts that VM, shares chosen
folders with it, and sits between it and the network.

1. **The host stays safe from what agents install and run.** Packages,
   scripts and tools live in the VM.
2. **Agents cannot act as you beyond what you allow.** The VM never holds a
   credential when there is any way to avoid it. You turn access on and off
   on the spot, and requests that use a credential can wait for your approval.

## Not covered by v1

- **Leaking shared files.** Outbound traffic is passed through by default, so
  an agent can upload anything in a shared folder.
- **Code you run on the host from a shared folder.** A VM can plant git hooks,
  `core.fsmonitor` in `.git/config`, build scripts. Running git, mix or npm on
  that folder on the host runs them. MDT's own Git tool does this too.
- **File grants after they are handed over.** See [Grant kinds](#grant-kinds).
- **Data sent out through DNS.** DNS never goes through MDT. Microsandbox
  answers port 53 to any address itself (`dig @8.8.8.8` works from the VM),
  so query names can carry data out.
- **VM agents using MDT notes, diagrams, or your host OptMem.**

## Decisions

| Date | Decision |
|---|---|
| 2026-11-11 | The VM gets placeholders, never real values, when the credential is sent over HTTP. MDT swaps them in on the way out. |
| 2026-11-11 | MDT is the only source of secrets and the only thing that inserts them. Microsandbox's own secret feature is unused. |
| 2026-11-11 | The proxy, TLS interception and HTTP handling are written in Elixir inside MDT. |
| 2026-11-11 | MDT creates, starts and stops the VM. The VM stops when MDT quits. |
| 2026-11-11 | Every kind of credential is supported. Each uses the safest delivery available. Handing over the real value is the last resort, labeled as such. |
| 2026-11-11 | Folders are shared one by one, read-write or read-only. |
| 2026-11-11 | Agents can ask for a grant from inside the VM in v1. |
| 2026-11-11 | The VM has its own OptMem. Your host OptMem is never shared. The VM's memory lives in a host folder and is included in MDT backups. |
| 2026-11-12 | Credentials are grouped into kinds, each with a setup guide that agents can read too. What no grant can express goes through a host command, approved each time. |
| 2026-11-12 | The image is your Containerfile plus MDT's layer, built with podman and tagged by the hash of what goes in. Superseded below. |
| 2026-11-12 | The base image is Ubuntu 26.04. Tools come from mise, languages included, with prebuilt Erlang. |
| 2026-11-12 | The image has a name you choose (`mdt_agent_sdb_image` by default) and a tag per build. MDT keeps the current tag and the 2 before it. |
| 2026-11-12 | MDT's own files (CA, git helper, profile, `memo`, agent instructions) reach the VM through `/mnt/mdt`, not the image. |
| 2026-11-12 | The VM's Home (`/root`) and Cache (`/cache`) are host folders that survive recreating. Recreating asks whether to keep, roll back or empty each. |
| 2026-11-12 | The VM's OptMem can start from a copy of yours. Its new memories come back only through a list you review. |
| 2026-11-12 | Agents in the VM are told that access comes only from MDT grants, and to name the grant they need instead of following a tool's usual login steps. |
| 2026-11-12 | Export is designed later. |

## Built so far

| Piece | Module | Notes |
|---|---|---|
| Sandbox per identity | `MDTClient.Sandbox.Server` | Grants, values, settings and the CA sealed in `sandbox.bin`; approvals and activity in memory. Values never appear in state dumps (`format_status/1`). |
| Proxy | `MDTClient.Sandbox.Egress`, `…Egress.Connection` | One listener per identity on the settings port. Tunnels, intercepts hosts a credential grant lists, one request per connection. Scrubs real values out of response headers. |
| CA | `MDTClient.Sandbox.CertificateAuthority` | `:public_key` only. Passes `openssl verify -x509_strict`. |
| Destinations | `MDTClient.Sandbox.Destinations` | Refused, private, public; network grant syntax `ADDRESS[:PORTS]`. |
| Describing requests | `MDTClient.Sandbox.Describe` | Tags for rules (`read`, `write`, `git_fetch`, `git_push`, `graphql_query`, `graphql_mutation`), facts, the agent's claims, the "allow similar" pattern. |
| VM | `MDTClient.Sandbox.Msb` | `msb create --replace --proxy … --net public,private`, one `--volume` per share, `/mnt/mdt` read-only, the VM's OptMem, placeholders as `--env`. Stopped when the identity locks or MDT quits gracefully. |
| Image | `MDTClient.Sandbox.Image` | See [The image](#the-image). |
| Inbox | `MDTClient.Sandbox.Inbox` | `/mnt/mdt/env.sh`, `git/<host>` for the credential helper, `tokens/<grant>` for gcloud, `files/` for file grants that are on. |

Tried live on 2026-11-12: build, create, lock (VM stopped), unlock, start;
inside the VM `gh api user` went out with the swapped value, git's helper
answered with the placeholder, a GraphQL mutation was held until approved,
example.com was tunnelled over HTTP/2, the LAN and this machine were
refused, the shared folder worked both ways.

### The image

The settings page holds your Containerfile (seeded from the zed-microsandbox
one). MDT appends its own layer (`priv/sandbox/mdt-layer.Containerfile`): the
identity's CA in the trust store, the per-tool CA variables,
`HEX_HTTP_TIMEOUT`, the git credential helper, the profile script that reads
`/mnt/mdt/env.sh`, `socat`, and `memo`. podman builds it and the result is
loaded into microsandbox.

The tag is `mdt-agentbox:` plus the hash of everything that goes in, so there
is no name to rename: change the Containerfile (or the CA) and the next build
gets a new tag, and the VM shows "recreate to apply". To use your own image,
put it in the `FROM` line; MDT's layer goes on top. The layer assumes a
Debian or Ubuntu base (`apt-get`, `update-ca-certificates`).

The build runs on the host in a rootless podman container, which isolates
less than the VM: install scripts in your Containerfile run there.

### Setting up each kind of credential

Each recipe carries a short guide, shown when adding a grant. The general
rule: keep the long-lived credential on the host, give MDT something it can
put on the wire, and give the VM only a placeholder.

| You have | Grant | How |
|---|---|---|
| A token or API key | stored (GitHub, Hex, API token) | Paste it once; it lives in your vault. |
| A CLI login on the host (`gcloud auth login`, `gh auth login`, `az login`) | minted | The grant holds a command that prints a short-lived token, run on the host when needed (`gcloud auth print-access-token`, `gh auth token`, `az account get-access-token --query accessToken -o tsv`). The login never leaves the host; tokens are cached for 10 minutes. |
| Something only reachable from here (VPN, a database through a tunnel) | network | List the destinations; for a database, run the tunnel on the host and list its exact address. |
| Something a tool must read itself (signing keys, client certificates) | file | Last resort, labelled: the VM holds the value while the grant is on. |
| Something none of these covers | host command (next) | Run one command on the host, with your approval each time. |

The same guides are what the agent channel will offer agents, so an agent in
the VM can tell you which grant it needs and how to set it up.

## Next

### Agent channel

As designed above: a vsock socket, an MCP server with `list_grants`,
`request_grant` and `list_recipes` (the guides).

### Host commands

The escape hatch for anything a grant cannot express. An agent asks, through
the agent channel, to run one command on the host, with a reason. It shows as
an approval like any other, with the exact command as the fact and the reason
as the agent's claim. Only "allow once" and "deny": no rule or allowance ever
lets a host command through unattended, since it runs as you, outside the VM.

On approval MDT runs it with `bash -lc` in a directory you approve (default:
the matching shared folder), with a timeout, and returns exit status and
output to the agent. Output can contain anything the command printed,
secrets included, so the card says so, and long output is cut.

### Export

Grants (not values, unless you ask), rules, settings and the VM's OptMem
belong in `.mdtexport`. Open: whether values travel at all, and how a CA moves
(a new CA means a rebuilt image).

## Overview

```
VM ──all TCP──▶ msb ──HTTP CONNECT ip:port──▶ MDT egress proxy (127.0.0.1)
                                               │
                                               ├─ loopback, link-local, host's own addresses → deny
                                               ├─ private ranges (VPN, LAN) → deny unless a network grant is on
                                               ├─ TLS to a host with an HTTP grant → intercept
                                               │     read request → placeholder? → rules → approve → swap → forward
                                               └─ anything else → blind byte tunnel (log host, bytes, duration)

VM ──vsock──▶ ~/.mdt_client/<id>/sandbox/agent.sock ──▶ agent channel (list_grants, request_grant)

/mnt/mdt (read-only, from host): CA certificate, placeholder env file, git credential helper, file grants
/root/.optmem (read-write, from host): the VM's own OptMem
```

The VM is created with `--proxy http://127.0.0.1:<port>`. All of its TCP goes
through MDT, and it cannot opt out the way it could ignore `HTTPS_PROXY`. The
setting is saved with the VM, so it also applies when Zed's SSH bridge boots
the VM. When MDT is not running, the VM has no internet. With an HTTP CONNECT
proxy, microsandbox blocks UDP other than DNS, so HTTP/3 cannot go around the
proxy. DNS goes to microsandbox's resolver, which forwards to the host's
systemd-resolved.

## Grant kinds

A grant is one credential or one piece of network access you can turn on and
off.

| Kind | What the VM gets | Approval | Turning it off |
|---|---|---|---|
| `http` | A placeholder. MDT swaps in the real value. | Per request | Takes effect on the next request. Complete, since the VM never had the value. |
| `network` | Reachability to listed hosts, address ranges and ports | Per connection | New connections refused, open ones closed |
| `file` | The real value, as a file in `/mnt/mdt/files` | None possible | File deleted. **Copies survive.** Only expiry at the provider ends it. |

Later kinds, which also keep the value on the host: `resign` (AWS SigV4: the VM
signs with dummy keys, MDT re-signs) and `signing` (an SSH agent over vsock,
approval per signature).

### Where real values come from

- **Stored:** kept in the identity's vault.
- **Minted:** a command MDT runs on the host that prints a short-lived token,
  for example `gcloud auth print-access-token --impersonate-service-account=…
  --lifetime=1800s`. MDT caches it until shortly before it expires. Prefer
  this: the long-lived credential never leaves your host tools.

### Recipes

When you add a grant, you pick what it is. The recipe fills in the safest
delivery and default rules. You can edit everything afterwards.

| Recipe | Kind | VM side | Hosts | Swapped in |
|---|---|---|---|---|
| GitHub token | `http` | `GITHUB_TOKEN`, `GH_TOKEN`, and a git credential helper for `https://github.com` | `api.github.com`, `github.com`, `uploads.github.com` | `Authorization` bearer/token (`gh` sends `token`), and the password inside Basic (git) |
| Hex API key | `http` | `HEX_API_KEY` | `hex.pm`, `repo.hex.pm` | `Authorization` (the whole value, no scheme) |
| Google Cloud | `http`, minted | `CLOUDSDK_AUTH_ACCESS_TOKEN_FILE` pointing at a placeholder | `*.googleapis.com` | `Authorization` bearer |
| Generic API token | `http` | an env var you name | hosts you list | a header you name |
| Network access (VPN) | `network` | nothing | address ranges, hostnames, ports | — |
| Database | `network` to a tunnel on the host (e.g. `cloud-sql-proxy --auto-iam-authn`) | nothing | the tunnel | — |
| File | `file` | the value at a path | — | — |

Placeholders look like the real thing (`ghp_` plus random characters for
GitHub), because some clients check the format. Each grant's placeholder is
created once and never changes.

## Data model

```elixir
%Grant{
  id: "g_7f3a",
  name: "GitHub (personal)",
  recipe: :github,
  kind: :http,                       # :http | :network | :file
  state: :on,                        # :on | :off
  expires_at: ~U[2026-11-11 21:30:00Z],  # nil = until turned off

  # :http
  env: ["GITHUB_TOKEN", "GH_TOKEN"],
  placeholder: "ghp_mdtQ9…",
  hosts: ["api.github.com", "github.com", "uploads.github.com"],
  carriers: [{:header, "authorization", [:bearer, :token, :basic_password]}],
  source: {:stored, "vault:grant:g_7f3a"},   # or {:minted, command, lifetime}
  rules: [%Rule{}],
  default_action: :ask,              # applies when no rule matches

  # :network
  destinations: [%{match: "10.20.0.0/16", ports: [443, 5432]}],
  per_connection: :ask,              # :allow | :ask

  # :file
  path: "/mnt/mdt/files/kubeconfig"
}

%Rule{
  match: %{methods: ["GET", "HEAD"], paths: ["/**"], facts: %{}},
  action: :allow                     # :allow | :ask | :deny
}
```

Changing a grant's state, rules or value never restarts the VM. Adding a new
`http` grant writes its placeholder to `/mnt/mdt/env.sh`, which new shells read.

## Proxy

### Each connection

MDT receives `CONNECT <ip>:<port>` from msb. Microsandbox resolved the name
itself, so MDT gets an IP, not a hostname.

1. **Deny** loopback, link-local, cloud metadata, and every address of the
   host's own network interfaces, docker bridges included. The list is read
   from the interfaces each time (`:inet.getifaddrs/0`). Without this, the VM
   reaches anything on the host that listens on all interfaces. The check
   reached a test server on the host's LAN address through the proxy.
   A denied CONNECT reaches the VM as a plain "connection refused", with no
   message. Agents learn why from `list_grants`.
2. **Private ranges** (RFC 1918, ULA, `100.64.0.0/10`): allowed only when an
   `on` network grant matches the IP and port. Grant hostnames are resolved
   with the host's DNS, which knows VPN names. With `per_connection: :ask`,
   the connection waits for approval.
3. **Peek** at the first bytes. For a TLS ClientHello, read the hostname
   (SNI).
4. If the hostname belongs to **any registered `http` grant, on or off**,
   intercept. Off grants are intercepted too, so the agent gets a clear answer
   instead of an auth failure from the provider.
5. Otherwise, **tunnel** bytes both ways without reading them.

### Each intercepted request

1. Finish the TLS handshake with a certificate MDT's CA makes for that
   hostname. Offer HTTP/1.1 only.
2. Read the request head. If `Host` does not match the TLS hostname, reject
   it. A mismatch would let a request say "github" to MDT while going
   somewhere else.
3. Look for placeholders in the grant's carriers. Basic auth is decoded and
   checked inside.
4. A placeholder that belongs to a grant **not** listing this host: block it
   and record a violation. An agent shipping a GitHub placeholder to another
   host is worth knowing about.
5. No placeholder: forward unchanged.
6. Placeholder, grant off or expired: reply `403` with
   `{"code": "mdt_grant_off", "grant": "...", "hint": "request_grant"}`.
7. Placeholder, grant on: describe the request, apply the rules → allow, deny
   or ask.
   - **Ask** holds the request. MDT reads the head plus the first few KB of the
     body (enough to describe it), then stops reading until you decide. TCP
     flow control makes the client wait, so a large upload is not buffered.
   - If you don't decide within the hold timeout (default 3 minutes), the
     reply is `403` with `{"code": "mdt_approval_timeout"}`.
   - Clients retry. Hex retries after its own timeout, and gcloud retries
     after an error. A request with the same grant, method, path and body
     hash as one already waiting joins that approval instead of adding a
     card, and your decision answers both.
8. On allow: get the value (minting if needed), swap it in, and connect to
   the real host. MDT resolves the name with its own DNS and verifies TLS
   normally. The IP the VM asked for is ignored, so a forged `/etc/hosts`
   entry cannot redirect a credential.
9. Stream the response back. If the real value appears in the response
   headers, MDT replaces it with the placeholder before the VM sees it.

Every request on a kept-alive connection goes through steps 2–9 again, so
turning a grant off affects the very next request.

`Upgrade` (websockets) on an intercepted host: the handshake goes through the
steps above, then bytes are tunnelled.

### Describing requests

An approval shows facts MDT worked out, not what the agent says.

| Describer | Facts |
|---|---|
| GitHub git | `push owner/repo: refs/heads/main abc123→def456` (read from the receive-pack commands); fetch/clone |
| GitHub GraphQL | operation type and name (`mutation createPullRequest`) |
| GitHub REST | method, resource path (`POST /repos/o/r/pulls`) |
| Hex | publish/retire/owner change, package and version |
| Generic | method, host, path, query, start of body |

Text the agent wrote (commit messages, PR bodies, a stated reason) is shown in
a separate, labeled area. It is a claim, never a fact.

### Default rules

| Recipe | Allowed and logged | Asks |
|---|---|---|
| GitHub | `GET`, `HEAD`, git fetch/clone, GraphQL queries | git push, GraphQL mutations, other writes |
| Hex | `GET` | everything else |
| Google Cloud | `GET` | everything else |
| Generic | — | everything |

Your choices on an approval card: allow once, allow requests matching this
rule for N minutes, deny once, deny and turn the grant off.

## Image and VM state

Decided and built 2026-11-12. Tried live through MDT with a throwaway
identity:
- the build (4.5 GB) and its record;
- creating with the memory copied from yours;
- `gh` refused by MDT with the grant off, and swapped with it on;
- git through the helper in `/mnt/mdt/bin`;
- Erlang 28.3 installed into Cache;
- recreating with Home kept (a snapshot was taken), then with Home emptied
  and Cache cleared;
- the review of the VM's memories.

Not tried live: a second build replacing the oldest, which the tests cover.

### The image

- **Base: Ubuntu 26.04.** mise downloads Erlang prebuilt from hex.pm only for
  the Ubuntu releases it knows. On Fedora, on Debian, and on 26.04 by default,
  it compiles Erlang from source: minutes per version.
  `MISE_ERLANG_PRECOMPILED_OS=ubuntu-26.04` (mise 2026.11.7) points it at
  hex.pm's 26.04 builds. Checked: Erlang 28.3 installs in 2 s and 27.3 in 3 s.
- **apt only for what mise can't do:** the C toolchain, git, openssh-client,
  curl, ca-certificates, unzip, xz, locales, postgresql-client, sqlite3,
  inotify-tools, tmux.
- **Everything else through mise.** It is installed at build time into
  `/usr/local/share/mise`, with the versions in `/etc/mise/config.toml`:
  - languages: Erlang, Elixir, Node, Python with uv, Rust, Go, Java with
    Kotlin;
  - CLIs: gh, gcloud, kubectl, pulumi, pnpm, rebar3, jq, yq, ripgrep, fd,
    shellcheck;
  - Claude Code and Codex as native binaries. Zed installs its own ACP
    adapters in the VM, in Home.

  Major versions are pinned, so a rebuild picks up the latest patches.
- **Switching versions:**
  - Versions installed at runtime go to `/cache/mise`, which is kept (see
    below).
  - mise honours each project's `.tool-versions` and `mise.toml`. Run
    `mise install` in a project; use `mise exec elixir@1.18 -- …` for
    one-offs.
  - The shims of both directories are on `PATH`, so a plain `bash -c` finds
    the tools.
  - Checked: a folder pinning Elixir 1.18.4-otp-27 and Erlang 27.3 installed
    both in 2.7 s.
  - Calling a tool whose dependency isn't installed yet fails instead of
    installing it, so run `mise install` first.
- **Nothing goes in `/root`:** Home is mounted over it.
- **Two exceptions to mise:**
  - Rust comes through rustup, which is what mise would run. The toolchains
    stay in the image, while `CARGO_HOME` lives in Cache.
  - Hex and rebar for the default Elixir are installed in the image, because
    mise keeps Mix's archives inside each Elixir version.
- **Build format:** podman builds with `--format docker`. Otherwise it
  ignores `SHELL`, and with it `pipefail`.

### MDT's layer

The layer holds only pointers into `/mnt/mdt`. So one image serves any
identity, the CA can change without a rebuild, and old tags keep working
with a newer MDT.
- `/etc/ssl/certs/ca-certificates.crt` links to `/mnt/mdt/ca-bundle.pem`:
  this machine's trusted roots plus the identity's CA.
  - A hook in `/etc/ca-certificates/update.d` puts the link back if a package
    regenerates the bundle.
  - The per-tool CA variables point at the same file.
- `/etc/profile.d/mdt.sh` links to `/mnt/mdt/profile.sh`, which reads
  `env.sh`. `BASH_ENV` points at it too, so every `bash -c` reads it.
- git's credential helper is `/mnt/mdt/bin/git-credential`.
- The image also sets the Cache variables (below), `HEX_HTTP_TIMEOUT` and
  `MDT_SANDBOX=1`.

### Name and history

- **Name and tags:** the image's name is a setting, `mdt_agent_sdb_image` by
  default. Each build is tagged with its date and number, like
  `2026-11-12.1`.
- **What MDT records per tag:** when it was built, the Containerfile, the
  tool versions it ended up with (`mise ls`), and its size.
- **Which tag the VM uses:** the newest build becomes current, and the VM
  shows "recreate to apply". Any kept tag can be made current again.
- **At most 3 tags:** the current one and the 2 before it. A build deletes
  the oldest from microsandbox and podman, but never the tag the VM was
  created from.
- **Why keep images:** rebuilding the same Containerfile later gives other
  versions, so going back needs the built images, not the recipes.

Agents can't change the image. It is built on the host, and the VM's root
filesystem is a copy that recreating discards. A bad image comes from what
the build downloaded, and going back a tag undoes it.

The build runs on the host in rootless podman, so it runs as little
third-party code as possible:
- apt packages are signed;
- mise checks checksums and attestations;
- the agents come as binaries, so no npm install scripts run.

### Home and Cache

Two folders inside the identity's sandbox folder, mounted read-write:

| | In the VM | Holds | If lost |
|---|---|---|---|
| Home | `/root` | Codex and Claude logins, shell history, Zed's server, agent settings, your mise config | log in again |
| Cache | `/cache` | versions installed at runtime (`MISE_DATA_DIR`); hex/mix, npm/pnpm, cargo, go, uv and pip caches | slower first builds |

Recreating the VM asks:
- **Home:** keep (default), go back to a snapshot, or start empty;
- **Cache:** keep (default) or clear.

Before each recreate, MDT snapshots Home (a reflink copy on btrfs) and labels
it with the tag the VM ran. It keeps at most 3, matching the tags. Going back
to an older tag offers the Home from when that tag was current.

Keeping Home has a cost: anything in it that runs code survives a recreate.
That includes hooks in `~/.claude/settings.json`, MCP servers in
`~/.codex/config.toml` and a planted `~/.bashrc`, plus poisoned packages in
Cache. "Start empty" is the real reset. The shell setup lives in `/etc`, so
an empty Home works.

msb's own snapshots stay unused: `msb restore` can't set `--proxy`.

### Recreating on demand

The VM card has "Recreate…" whenever the VM exists, not only when settings
changed, so "start empty" is always within reach.

### Instructions for agents in the VM

Before each start, MDT writes its block at the top of `~/.claude/CLAUDE.md`
and `~/.codex/AGENTS.md` in Home, between markers. The rest of each file is
left alone. The same text is at `/mnt/mdt/AGENTS.md`. It says:
- Access comes only from MDT grants. Agents run no login commands, ask for
  no pasted tokens, and write no tokens into files or variables. When access
  is missing, they name the grant for you to add or turn on in MDT.
- What MDT's answers mean: the `mdt_*` error codes, and requests held for
  your approval.
- `/mnt/mdt/grants.md`, rewritten on every change, lists the grants and
  their state.
- The OptMem block.
- mise: run `mise install` in a project first.

## Agent channel

MDT listens on a Unix socket connected to the VM through vsock
(`--vsock <socket>:5000`). The VM has no network route to the host. Inside the
VM, agents use it as a stdio MCP server: `socat - VSOCK-CONNECT:2:5000`.
Microsandbox opens the host socket for each connection. So when MDT restarts,
the channel works again without touching the VM. While MDT is down, the VM
gets "connection reset".

This is a separate MCP server from the existing one, built on the same
`MDTClient.MCP.Protocol` code, with only two tools:

- `list_grants`: name, kind, state, expiry, env vars, hosts, a summary of the
  rules. Never values.
- `request_grant(name | need, minutes, reason)`: asks for an existing grant
  to be turned on, or describes a credential that does not exist yet. It
  waits up to 2 minutes for your answer, then returns `pending`.

Requests are rate-limited. Any process in the VM can call these; that is
accepted, since all they can do is ask.

## VM

- **Checks:** KVM is available, `msb` is at a supported version, the image
  exists.
- **Image:** see [Image and VM state](#image-and-vm-state). The checks
  showed what TLS needs: the `ca-certificates` package (without it Erlang
  finds no CAs at all), MDT's CA in the system bundle (curl, git, `gh`,
  Python's `ssl`), `HEX_CACERTS_PATH` and `CLOUDSDK_CORE_CUSTOM_CA_CERTS_FILE`.
  Hex gives up after 15 seconds by default, shorter than any approval, hence
  `HEX_HTTP_TIMEOUT`.
- **Created with:**
  - `--proxy http://127.0.0.1:<port>`;
  - `--net public,private`, so private ranges reach MDT, which gates them.
    Access to the host stays blocked;
  - one mount per shared folder;
  - the read-only `/mnt/mdt`;
  - the OptMem folder;
  - Home at `/root` and Cache at `/cache`;
  - `--vsock`;
  - CPU and memory limits.
- **Nothing in the root filesystem is kept.** `msb modify` cannot change
  mounts, the proxy, vsock or network settings. Changing any of them means
  removing the VM and creating it again from the image, which takes seconds
  with the image cached. What survives is Home, Cache and the VM's OptMem
  (see [Home and Cache](#home-and-cache)); packages installed with apt at
  runtime vanish, so they belong in the Containerfile.
- **Lifecycle:** MDT calls the `msb` CLI. Settings that need recreating are
  shown as "recreate to apply". The VM stops when MDT quits.
- **Started from Zed:** `msb ssh` boots a stopped VM by itself. That VM still
  goes through the proxy, so with MDT closed it has no internet.

### Shared folders

- You pick each folder. It's mounted at the same path as on the host,
  read-write or read-only.
- Read-only is enforced on the host's side. Root in the VM can remount the
  folder read-write, and `/proc/mounts` then claims it's writable, but writes
  still fail.
- Picks cannot overlap. In the check, root in the VM unmounted a read-only
  folder sitting inside a read-write one and wrote to the host folder
  underneath.
- MDT refuses your home folder itself, `~/.ssh`, `~/.optmem`, MDT's data
  folder, and other credential folders.
- Changes recreate the VM (see above).
- Files and folders the VM creates appear on the host owned by you, with
  modes 0600 and 0700.
- File locks (`flock`) do not cross between host and VM. Exclusive creates
  (`O_EXCL`) do, which is what git's `index.lock` uses, so git on both sides
  of a shared repo stays safe.

### The VM's OptMem

- Kept on the host at `~/.mdt_client/<id>/sandbox/optmem`, mounted read-write
  at `/root/.optmem`. It survives deleting, rebuilding or upgrading the VM,
  and emptying Home.
- Before each start MDT copies the host's `memo` into it, and runs
  `memo init` on it when it holds no memory. The check ran `init`, `note`
  and `wake` in the VM on a host-mounted folder.
- **Starting from your memory:** a checkbox when creating the VM, and a
  button while it is stopped.
  - It copies your memory's `LOG.txt`, `TREE/` and `config` (what
    `memo sync` shares) into the VM's, under memo's lock, replacing what the
    VM had.
  - MDT records how many memories the copy held: the seed point.
  - It copies everything, including work memories that reach this machine
    through sync.
- **Bringing memories back:**
  - MDT lists what the VM noted after the seed point. It reads them as data:
    fixed 320-byte records, skipping a partial last one.
  - You tick which to keep. MDT adds them to your memory with `memo note`,
    marked `[vm]`, and memo asks your next agent session for the summaries.
  - It is never automatic: your agents act on their memory, so a note
    planted by a VM agent would be a way out of the VM. For the same reason,
    the VM never gets access to your memory's git repo.
- `flock` in the VM doesn't reach the host, so MDT writes the VM's memory
  only while the VM is stopped.
- It is a Transfer participant, so `.mdtexport` backups include it.
  - `memo` locks with `flock`, which does not reach the host. So the
    backup pauses the VM (`msb pause`, then `msb resume`) while it copies the
    folder, or copies it while the VM is stopped.
  - Only the VM writes the folder, so the missing lock doesn't matter
    otherwise.
- It is written by the VM, so the host treats it as data. MDT never runs
  anything from it, and no host agent is pointed at it.
- It sits on disk unencrypted, because the VM must read it live. This is the
  one exception to MDT encrypting what it stores.

## Where things live

Everything belongs to the signed-in identity:
- **Encrypted, like other MDT data:** grants, stored values, rules, VM
  settings, MDT's CA key, the activity log.
- **Plaintext, readable by the VM:** `/mnt/mdt` (holds no real values except
  file grants), the VM's OptMem, Home and Cache. Home holds the VM's own
  logins (Codex, Claude). Its snapshots sit next to it, readable by MDT
  only. On this machine the disk itself is encrypted.

Locking MDT pauses every grant. Without the CA key, MDT tunnels everything.
Placeholders then reach providers unswapped and fail to authenticate, which
is harmless. The VM keeps running.

The activity log records grant changes, swaps, approvals, denials, violations
and connections (host, IP, port, bytes, duration). It never records a real
value.

## Screens

The tool is an entry in `MDTClient.Tools`.

- **Overview:**
  - VM status: start, stop, "recreate to apply";
  - waiting approvals and agent requests;
  - grants that are on, with time left.
- **Grants:**
  - the list, each with a switch and duration choices (15 min, 1 h, until
    turned off);
  - adding a grant through a recipe;
  - per grant: rules, last used, its own activity.
- **Approvals:** waiting cards, with facts and the agent's claims kept apart;
  history below.
- **Activity:** the log, filterable by grant, host and outcome.
- **Settings:** image, CPU and memory, shared folders, private ranges.
  Changing folders, network or vsock recreates the VM; MDT says so before
  applying.

Approvals and agent requests raise a desktop notification. This needs
`tauri-plugin-notification`, which MDT's shell does not include yet.

## Components

Each has one job. Proposed modules sit under `lib/mdt_client/sandbox/`.

| Component | Job |
|---|---|
| `VM` | Turns settings into `msb` commands, starts, stops, reports status |
| `Settings` | VM settings for the identity, and what needs a restart |
| `Shares` | Validates folder picks, produces mounts |
| `Inbox` | Writes `/mnt/mdt` atomically: CA certificate, `env.sh`, credential helper, file grants |
| `CertificateAuthority` | Creates the CA, makes and caches a certificate per host |
| `Grants` | Grants, their state and expiry; the source of truth |
| `Recipes` | Defaults for each recipe |
| `Credentials` | Returns the value for a grant: stored or minted, with caching |
| `Egress.Listener` | Accepts msb's CONNECTs (Thousand Island, already a dependency through Bandit) |
| `Egress.Destination` | Deny, private-range gate, intercept or tunnel |
| `Egress.Tunnel` | Moves bytes both ways and counts them |
| `Egress.Interceptor` | TLS, HTTP/1.1, holding, forwarding (Mint, already a dependency) |
| `Egress.Substitution` | Finds placeholders in carriers and swaps them, including Basic auth |
| `Rules` | Matches a described request to allow, ask or deny; temporary allowances |
| `Describers.*` | Turn requests into facts, one per provider |
| `Approvals` | Waiting requests and connections, timeouts, decisions, PubSub |
| `Activity` | The append-only log |
| `AgentChannel` | The vsock MCP server |
| `VMMemory` | The OptMem folder and its Transfer participant |

## Guarantees to test

1. No real value is written to `/mnt/mdt`, the activity log, application logs
   or the VM environment. File grants are the only exception.
2. MDT never connects for the VM to loopback, link-local, metadata or the
   host's own addresses.
3. A value is swapped in only through a grant's carriers, only on requests
   MDT itself sends to one of that grant's hosts, resolved with MDT's DNS and
   with TLS verified.
4. A placeholder going to a host outside its grant is blocked and logged.
5. Turning a grant off, or its expiry, affects the next request. Turning a
   network grant off closes its open connections.
6. A locked MDT swaps nothing. A stopped MDT leaves the VM without internet.
7. Nothing in the VM can reach MDT's web server. The agent channel offers only
   `list_grants` and `request_grant`.
8. Nothing in the VM can approve its own requests.

## Checks (2026-11-11)

These ran on Fedora 44 with msb 0.7.14. They used a throwaway proxy in plain
OTP and stock images (`python:3.12-slim-bookworm`, `elixir:1.18-slim`,
`google-cloud-cli:slim`). No real credentials were used: each placeholder was
swapped for an invalid value, and each provider's rejection showed that the
swapped value reached it. Scripts and logs are in
`tmp/agent_sandbox_spikes/` (gitignored).

| # | Check | Result |
|---|---|---|
| 1 | VM's own ClientHello reaches MDT | **Yes.** Without `--tls-intercept`, microsandbox does not decrypt. The VM saw the real certificate. CONNECT carries only the IP, and SNI is readable. |
| 1 | Proxy kept across stop, start and `msb ssh` boots | **Yes.** It's saved as `outbound_proxy`. A VM booted by `msb ssh` with MDT down has no internet. |
| 1 | Plain HTTP, port 22, private ranges, the host's LAN address | All arrive at the proxy as CONNECT. |
| 1 | `host.microsandbox.internal`, the VM's own `127.0.0.1` | Refused. Neither reaches the proxy. |
| 1 | Non-DNS UDP | Blocked (NTP query timed out). |
| 1 | DNS | Goes to microsandbox's resolver, then the host's systemd-resolved (`_gateway` resolved to the router). Private-address answers pass. Port 53 to any address is answered too. |
| 2 | TLS termination in Elixir | `:gen_tcp.unrecv/2` with the peeked bytes, then `:ssl.handshake/3`, works. Offering only HTTP/1.1 made curl drop h2. |
| 2 | Carriers | `gh`: `Authorization: token <ph>`, including `POST /graphql`. git: anonymous first, then Basic with the placeholder as password after the 401. Hex: the whole `Authorization` value, no scheme. gcloud: `Bearer`. All four swapped and rejected upstream. |
| 2 | CA trust | System store is enough for curl, git and `gh`. Hex needs `HEX_CACERTS_PATH`. gcloud needs `CLOUDSDK_CORE_CUSTOM_CA_CERTS_FILE`. Erlang needs `ca-certificates` installed. |
| 2 | 180-second hold | `gh`, git and gcloud wait. Hex gives up after 15 seconds and retries twice; with `HEX_HTTP_TIMEOUT=300` it waits. gcloud retried once after the 401. |
| 3 | VPN | **Not run: no VPN on this machine.** Covered so far: DNS reaches systemd-resolved (where NetworkManager registers VPN domains), and private destinations go through the proxy. Still to do: resolving a VPN name and reaching a VPN host while connected. |
| 4 | Same-path mounts | Work. |
| 4 | Read-only | Enforced by the host, even after a remount inside the VM. |
| 4 | Read-only inside read-write | **Not safe.** Unmounting it exposed the host folder underneath, which was writable. |
| 4 | Changing mounts live | **Not possible.** `msb modify` has no mount option, and `msb restore` has no `--proxy`. |
| 5 | vsock to a host Unix socket | Works both ways. Survives the host server restarting. "Connection reset" while it's down. |
| 6 | OptMem in the VM | `init`, `note`, `wake` work. `flock` does not cross host and VM; `O_EXCL` does. |

What changed in the design:
- The VM's root filesystem is disposable. `/root` is a named volume, and
  folder changes recreate the VM.
- Image requirements: `ca-certificates`, the per-tool CA variables, and
  `HEX_HTTP_TIMEOUT`.
- A retried request joins the approval already waiting.
- The host's own addresses are read from its interfaces.
- The VM is paused while its OptMem is backed up.
- DNS exfiltration is listed as not covered.

Still open: the live VPN check, and generating certificates in Elixir (the
checks used openssl; `:public_key` or the `x509` package are the options).

## Later

- `resign` grants (AWS) and `signing` grants (SSH agent with approval per
  signature).
- Replacing the real value with the placeholder in response bodies, not only
  headers.
- Warnings when a picked folder contains likely secrets (`.env`, `*.pem`,
  tokens in git remote URLs).
- MDT's Git tool running git with dangerous config overridden on folders the
  VM can write.
- An allowlist-only egress mode, to stop leaks of shared files.
- VM agents using MDT notes and diagrams through the agent channel.
- Automating the OptMem round trip: MDT offering the review whenever the VM
  stops, in the Approvals queue.
- Seeding the VM's OptMem with only some projects' memories.
- Containers inside the VM (klife's Kafka test clusters): unchecked.
