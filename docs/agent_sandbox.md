# Agent Sandbox

Status (2026-11-12): the first slice is built and was tried live with a real
VM: the image build, the VM's lifecycle, the egress proxy (tunnels, TLS
interception, placeholder swaps, approvals), grants with values in the
vault, and every screen. Not built yet: export, and the live VPN check. See
[Built so far](#built-so-far) and [Next](#next).

Built later on 2026-11-12: host commands, the escape hatch for what no
grant can express, and a description of your machine for agents. See
[Host commands](#host-commands).

Built and tried live (2026-11-12): the image and the VM's state. See
[Image and VM state](#image-and-vm-state).

Built later on 2026-11-12: generic grant types with presets, every use
approved, agents asking through the `mdt` command, and the full request on
approvals. See [Grants and approvals](#grants-and-approvals). The `mdt`
command was checked over a real VM's vsock; a VM created before this needs
recreating to get the channel.

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
  that folder on the host runs them. MDT's own Git tool does this too, and
  so does a host command you approve there; its card says so when it can
  tell, but the hints are not a review.
- **File grants after they are handed over.** See [Grant kinds](#grant-kinds).
- **Data sent out through DNS.** DNS never goes through MDT. Microsandbox
  answers port 53 to any address itself (`dig @8.8.8.8` works from the VM),
  so query names can carry data out.
- **VM agents using MDT notes, diagrams, or your host OptMem.**

## Decisions

| Date       | Decision                                                                                                                                                         |
| ---------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 2026-11-11 | The VM gets placeholders, never real values, when the credential is sent over HTTP. MDT swaps them in on the way out.                                            |
| 2026-11-11 | MDT is the only source of secrets and the only thing that inserts them. Microsandbox's own secret feature is unused.                                             |
| 2026-11-11 | The proxy, TLS interception and HTTP handling are written in Elixir inside MDT.                                                                                  |
| 2026-11-11 | MDT creates, starts and stops the VM. The VM stops when MDT quits.                                                                                               |
| 2026-11-11 | Every kind of credential is supported. Each uses the safest delivery available. Handing over the real value is the last resort, labeled as such.                 |
| 2026-11-11 | Folders are shared one by one, read-write or read-only.                                                                                                          |
| 2026-11-11 | Agents can ask for a grant from inside the VM in v1.                                                                                                             |
| 2026-11-11 | The VM has its own OptMem. Your host OptMem is never shared. The VM's memory lives in a host folder and is included in MDT backups.                              |
| 2026-11-12 | Credentials are grouped into kinds, each with a setup guide that agents can read too. What no grant can express goes through a host command, approved each time. |
| 2026-11-12 | The image is your Containerfile plus MDT's layer, built with podman and tagged by the hash of what goes in. Superseded below.                                    |
| 2026-11-12 | The base image is Ubuntu 26.04. Tools come from mise, languages included, with prebuilt Erlang.                                                                  |
| 2026-11-12 | The image has a name you choose (`mdt_agent_sdb_image` by default) and a tag per build. MDT keeps the current tag and the 2 before it.                           |
| 2026-11-12 | MDT's own files (CA, git helper, profile, `memo`, agent instructions) reach the VM through `/mnt/mdt`, not the image.                                            |
| 2026-11-12 | The VM's Home (`/root`) and Cache (`/cache`) are host folders that survive recreating. Recreating asks whether to keep, roll back or empty each.                 |
| 2026-11-12 | The VM's OptMem can start from a copy of yours. Its new memories come back only through a list you review.                                                       |
| 2026-11-12 | Agents in the VM are told that access comes only from MDT grants, and to name the grant they need instead of following a tool's usual login steps.               |
| 2026-11-12 | Export is designed later.                                                                                                                                        |
| 2026-11-12 | Grants have three generic types: token, network, file. Presets (GitHub, Hex, Google Cloud, database tunnel) only fill the form. Supersedes recipes.             |
| 2026-11-12 | Every grant says what it is for, in your words. Agents read it to find the grant they need.                                                                      |
| 2026-11-12 | Every use of a grant waits for your approval. Rules are gone; the shortcuts are allowances: uses like one you approved, or every use, for a while.               |
| 2026-11-12 | Two types of approval in one queue: agents asking for a grant (activation), and uses of a grant (requests, connections).                                         |
| 2026-11-12 | Agents ask with the `mdt` command over vsock, not MCP: any agent or script can run it with no setup. MCP can come later on the same socket.                      |
| 2026-11-12 | A held request shows in full (headers, body) and copies as curl, as HTTP or just its body. It stays in memory only.                                              |
| 2026-11-12 | Host commands: an agent asks to run one command on your machine. It runs once per approval, as you, outside the VM. No allowance ever covers one.                |
| 2026-11-12 | A command's text travels in the ask and is exactly what runs. The card shows it in full, with hints such as "runs files the VM can write".                       |
| 2026-11-12 | Per command, you choose whether its output goes straight back to the agent or waits for you to release it.                                                       |
| 2026-11-12 | MDT describes your machine to agents (`mdt host`, `/mnt/mdt/host.md`): OS, architecture, shell, shares, tools, your notes. Agents never probe it themselves.     |
| 2026-11-12 | Host commands cover most of what file grants were for (move the work to the value, not the value to the VM). File grants stay for long-lived processes in the VM. |
| 2026-11-13 | Ports listening in the VM are forwarded by themselves to the VM's own loopback address on your machine (`127.77.X.Y`), with the same numbers. No hostname.      |
| 2026-11-13 | Forwarding goes over msb's SSH server with an OpenSSH control master and MDT's own key, not msb's published ports, which need restarts and miss loopback.      |
| 2026-11-13 | MDT ships its own msb (v0.7.14 with the live-sharing patch, and its libkrunfw) and keeps its state in its own microsandbox home. An `msb` you install is never used. |
| 2026-11-13 | Disk is a setting: the root disk (64 GiB, sparse) and a write budget per read-write folder per boot (64 GiB), instead of microsandbox's silent 4 GiB for both. |

## Built so far

| Piece                | Module                                           | Notes                                                                                                                                                                                                     |
| -------------------- | ------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Sandbox per identity | `MDTClient.Sandbox.Server`                       | Grants, values, settings and the CA sealed in `sandbox.bin`; approvals and activity in memory. Values never appear in state dumps (`format_status/1`).                                                    |
| Proxy                | `MDTClient.Sandbox.Egress`, `…Egress.Connection` | One listener per identity on the settings port. Tunnels, intercepts hosts a credential grant lists, one request per connection. Scrubs real values out of response headers.                               |
| CA                   | `MDTClient.Sandbox.CertificateAuthority`         | `:public_key` only. Passes `openssl verify -x509_strict`.                                                                                                                                                 |
| Destinations         | `MDTClient.Sandbox.Destinations`                 | Refused, private, public; network grant syntax `ADDRESS[:PORTS]`.                                                                                                                                         |
| Describing requests  | `MDTClient.Sandbox.Describe`                     | Facts (git ref updates, GraphQL operation, REST endpoint), the agent's claims, the "allow similar" pattern. It decides nothing.                                                                           |
| Showing requests     | `MDTClient.Sandbox.RequestView`                  | Headers with placeholders named, bodies decoded (JSON, GraphQL, form, git pkt-lines, text, hex), curl and raw HTTP with `$VARIABLE` for the placeholder.                                                 |
| Agent channel        | `MDTClient.Sandbox.Channel`                      | A Unix socket per identity, joined to the VM's vsock port 5000. Speaks the `mdt` command's one-line protocol.                                                                                            |
| VM                   | `MDTClient.Sandbox.Msb`                          | MDT's own `msb` (see [Runtime](#runtime)). `msb create --replace --proxy … --net public,private --vsock …`, one `--volume` per share, `/mnt/mdt` read-only, the VM's OptMem, placeholders as `--env`. Stopped when the identity locks or MDT quits. |
| Image                | `MDTClient.Sandbox.Image`                        | See [The image](#the-image).                                                                                                                                                                              |
| Inbox                | `MDTClient.Sandbox.Inbox`                        | `/mnt/mdt/env.sh`, `bin/mdt`, `git/<host>` for the credential helper, `tokens/<grant>` for every token grant, `files/` for file grants that are on, `host.md`.                                           |
| Host commands        | `…HostCommand`, `…HostRun`, `…HostInfo`          | Checking and describing an ask (place, facts, hints); running it under `timeout` with capped output and a killable process group; the machine's description. See [Host commands](#host-commands).      |
| Ports                | `…Ports`, `…Forwarder`, `…Forwarder.SSH`         | The VM's address, reading `ss`, what to forward and why not; one process per running VM keeping the SSH connection and its forwards. See [Ports](#ports).                                              |

Tried live on 2026-11-12: build, create, lock (VM stopped), unlock, start;
inside the VM `gh api user` went out with the swapped value, git's helper
answered with the placeholder, a GraphQL mutation was held until approved,
example.com was tunnelled over HTTP/2, the LAN and this machine were
refused, the shared folder worked both ways.

### The image

The settings page holds your Containerfile. MDT appends its own layer
(`priv/sandbox/mdt-layer.Containerfile`), builds it with podman, and loads
the result into microsandbox. Builds get date-and-number tags; Home and
Cache survive recreating. See [Image and VM state](#image-and-vm-state)
for the current image, shell setup, upgrade steps and persistence rules.

The build runs on the host in a rootless podman container, which isolates
less than the VM: install scripts in your Containerfile run there.

### Setting up each kind of credential

Each type and preset carries a short guide, shown when adding a grant. The
general rule: keep the long-lived credential on the host, give MDT something
it can put on the wire, and give the VM only a placeholder.

| You have                                                                   | Grant                           | How                                                                                                                                                                                                                                                                      |
| -------------------------------------------------------------------------- | ------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| A token or API key                                                         | token, stored                   | Paste it once; it lives in your vault.                                                                                                                                                                                                                                   |
| A CLI login on the host (`gcloud auth login`, `gh auth login`, `az login`) | token, minted                   | The grant holds a command that prints a short-lived token, run on the host when needed (`gcloud auth print-access-token`, `gh auth token`, `az account get-access-token --query accessToken -o tsv`). The login never leaves the host; tokens are cached for 10 minutes. |
| Something only reachable from here (VPN, a database through a tunnel)      | network                         | List the destinations; for a database, run the tunnel on the host and list its exact address.                                                                                                                                                                            |
| A key or file a tool reads for one job (SSH keys, a kubeconfig, signing)   | host command                    | The job runs here, with your approval each time, and only its output goes back. The value never reaches the VM.                                                                                                                                                         |
| Something a process in the VM must read for long (a client certificate)    | file                            | Last resort, labelled: the VM holds the value while the grant is on.                                                                                                                                                                                                     |
| Something none of these covers                                             | host command                    | Run one command on the host, with your approval each time.                                                                                                                                                                                                               |

Agents in the VM don't see the guides. They see each grant's own words for
what it is for (`mdt grants`), and describe what's missing in their own
(`mdt request --need`).

## Next

### Export

Grants (not values, unless you ask), settings and the VM's OptMem
belong in `.mdtexport`. Open: whether values travel at all, and how a CA moves
(a new CA means a rebuilt image).

## Overview

```
VM ──all TCP──▶ msb ──HTTP CONNECT ip:port──▶ MDT egress proxy (127.0.0.1)
                                               │
                                               ├─ loopback, link-local, host's own addresses → deny
                                               ├─ private ranges (VPN, LAN) → deny unless a network grant is on
                                               ├─ TLS to a host with an HTTP grant → intercept
                                               │     read request → placeholder? → allowance or approve → swap → forward
                                               └─ anything else → blind byte tunnel (log host, bytes, duration)

VM ──vsock:5000──▶ $XDG_RUNTIME_DIR/mdt/mdt-sandbox-<id>.sock ──▶ agent channel (`mdt grants`, `mdt request`, `mdt run`, `mdt host`, `mdt wait`)
                                                                   │
                                                                   └─ `mdt run`, once you approve it ──▶ bash -lc on the host, as you

/mnt/mdt (read-only, from host): CA certificate, placeholder env file, the `mdt` command, git credential helper, file grants, host.md
/root/.optmem (read-write, from host): the VM's own OptMem
```

The VM is created with `--proxy http://127.0.0.1:<port>`. All of its TCP goes
through MDT, and it cannot opt out the way it could ignore `HTTPS_PROXY`. The
setting is saved with the VM, so it also applies when Zed's SSH bridge boots
the VM. When MDT is not running, the VM has no internet. With an HTTP CONNECT
proxy, microsandbox blocks UDP other than DNS, so HTTP/3 cannot go around the
proxy. DNS goes to microsandbox's resolver, which forwards to the host's
systemd-resolved.

<a id="grants-and-approvals"></a>

## Grant kinds

A grant is one piece of access you can turn on and off. It has one of three
generic types, none tied to a provider, and your own words for what it is
for, which agents read to find the grant they need.

| Type      | What the VM gets                                                                   | Approval       | Turning it off                                                                |
| --------- | ---------------------------------------------------------------------------------- | -------------- | ----------------------------------------------------------------------------- |
| `token`   | A placeholder, in variables, in a token file, and as git's password if you choose. | Per request    | Takes effect on the next request. Complete, since the VM never had the value. |
| `network` | Reachability to listed hosts, address ranges and ports                             | Per connection | New connections refused, open ones closed                                     |
| `file`    | The real value, as a file in `/mnt/mdt/files`                                      | None possible  | File deleted. **Copies survive.** Only expiry at the provider ends it.        |

A token grant names:

- the **hosts** the value may go to. MDT swaps the placeholder in any header
  of a request to one of them, Basic credentials included;
- **variables** holding the placeholder (`GH_TOKEN`), and variables naming
  the **token file** that holds it (`CLOUDSDK_AUTH_ACCESS_TOKEN_FILE`). The
  file, `/mnt/mdt/tokens/<grant>`, is always there;
- whether **git** over HTTPS gets it, from MDT's credential helper, for its
  exact hosts;
- how the placeholder **starts** (`ghp_`, `sk-`), for clients that check
  the format.

Later types, which also keep the value on the host: `resign` (AWS SigV4: the
VM signs with dummy keys, MDT re-signs) and `signing` (an SSH agent over
vsock, approval per signature).

### Where real values come from

- **Stored:** kept in the identity's vault.
- **Minted:** a command MDT runs on the host that prints a short-lived token,
  for example `gcloud auth print-access-token --impersonate-service-account=…
--lifetime=1800s`. MDT caches it until shortly before it expires. Prefer
  this: the long-lived credential never leaves your host tools.

### Presets

When you add a grant, you pick its type, or a preset for a tool whose
details are known. A preset only fills the form; what it makes is a plain
grant you can edit, and nothing in MDT looks at the preset again except for
its icon.

| Preset          | Type                                                                          | VM side                                                       | Hosts                                                |
| --------------- | ----------------------------------------------------------------------------- | ------------------------------------------------------------- | ---------------------------------------------------- |
| GitHub          | `token`, placeholder `ghp_…`                                                  | `GITHUB_TOKEN`, `GH_TOKEN`, git's credential helper           | `api.github.com`, `github.com`, `uploads.github.com` |
| Hex             | `token`                                                                       | `HEX_API_KEY`                                                 | `hex.pm`, `repo.hex.pm`                              |
| Google Cloud    | `token`, minted (`gcloud auth print-access-token`), placeholder `ya29.mdt…`   | `CLOUDSDK_AUTH_ACCESS_TOKEN_FILE` naming the token file       | `*.googleapis.com`                                   |
| Database tunnel | `network` to a tunnel on the host (e.g. `cloud-sql-proxy --auto-iam-authn`)   | nothing                                                       | `127.0.0.1:5433`                                     |

Placeholders look like the real thing where a preset says so, because some
clients check the format. Each grant's placeholder is created once and
never changes.

Grants saved before types existed are brought up to date when MDT loads
them: `http` becomes `token`, the recipe becomes the preset, Google's token
file variable moves to the token file variables, GitHub's grants answer git.
Their rules are dropped, so uses that went through silently now ask.

## Data model

```elixir
%Grant{
  id: "github-personal",
  name: "GitHub (personal)",
  kind: :token,                      # :token | :network | :file
  preset: :github,                   # its icon; nothing else depends on it
  purpose: "Push to oliveigah/klife and open PRs there",
  state: :on,                        # :on | :off
  expires_at: ~U[2026-11-11 21:30:00Z],  # nil = until turned off

  # :token
  placeholder: "ghp_mdtQ9…",
  hosts: ["api.github.com", "github.com", "uploads.github.com"],
  env: ["GITHUB_TOKEN", "GH_TOKEN"],
  file_env: [],                      # variables naming /mnt/mdt/tokens/<id>
  git: true,
  source: :stored,                   # or {:minted, command}

  # :network
  destinations: ["10.20.0.0/16:443,5432"],

  # :file
  path: "/mnt/mdt/files/kubeconfig",

  # :token and :network
  allowances: [%Allowance{}]
}

%Allowance{
  pattern: :all,                     # every use, or "POST github.com/o/r.git/git-receive-pack"
  until: ~U[2026-11-11 21:00:00Z]    # nil = while the grant stays on
}

%Approval{
  kind: :activation,                 # :activation | :request | :connection | :command
  grant_id: "github-personal",       # nil for an ask no grant meets yet, and for commands
  agent: "claude", minutes: 60, reason: "…", need: nil,   # activations
  request: %{method: …, headers: …, body: …},             # requests, in memory only
  script: "kubectl get pods", dir: "/home/me/projects/x", timeout: 120,  # commands
  stage: :run,                       # commands: :run, then :output when you see it first
  run: %{state: :running | :done, output_to: :send | :review, exit: 0,
         output: "…", bytes: 512, cut: 0, stopped: false, timed_out: false},
  facts: […], claims: […], hints: […], pattern: "…",
  status: :waiting,                  # :waiting | :allowed | :denied | :timed_out
  decision: nil
}
```

Changing a grant's state, allowances or value never restarts the VM. Adding
a new token grant writes its placeholder to `/mnt/mdt/env.sh`, which new
shells read.

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
   message. Agents learn why from `mdt grants`.
2. **Private ranges** (RFC 1918, ULA, `100.64.0.0/10`): allowed only when an
   `on` network grant matches the IP and port. Grant hostnames are resolved
   with the host's DNS, which knows VPN names. The connection waits for
   approval unless an allowance covers its address and port.
3. **Peek** at the first bytes. For a TLS ClientHello, read the hostname
   (SNI).
4. If the hostname belongs to **any registered token grant, on or off**,
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
   `{"code": "mdt_grant_off", "grant": "...", "error": "... mdt request <id> ..."}`.
7. Placeholder, grant on: describe the request. An allowance covering it
   lets it through; otherwise it asks.
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

| Describer      | Facts                                                                                               |
| -------------- | --------------------------------------------------------------------------------------------------- |
| GitHub git     | `push owner/repo: refs/heads/main abc123→def456` (read from the receive-pack commands); fetch/clone |
| GitHub GraphQL | operation type and name (`mutation createPullRequest`)                                              |
| GitHub REST    | method, resource path (`POST /repos/o/r/pulls`)                                                     |
| Hex            | publish/retire/owner change, package and version                                                    |
| Generic        | method, host, path, query, start of body                                                            |

Text the agent wrote (commit messages, PR bodies, a stated reason) is shown in
a separate, labeled area. It is a claim, never a fact.

### Approvals

Every use of a grant waits for you: each request carrying a token grant's
placeholder, and each connection through a network grant. There are no
rules deciding by method or path; what a request does depends on the API,
and guessing that per provider doesn't generalize. Shortcuts are
allowances, which you add on purpose:

- **Allow similar** - uses like this one (same method and endpoint, the
  same GraphQL operation, the same address and port), for 10 minutes, 1 hour
  or while the grant stays on;
- **Allow every use** - everything the grant covers, for as long. Also
  offered when you turn a grant on for an agent, and on the grant's page.

Your choices on a use: allow once, allow similar for…, allow every use
for…, deny, deny and turn the grant off.

Agents asking for a grant are approvals too (activations), in the same
queue. You choose how long it stays on and whether each use still asks.
See [Agent channel](#agent-channel).

A held request shows in full, as MDT received it: the request line, every
header with placeholders shown as their grant's name, and up to 64 KiB of
body, decoded. It copies as curl (with `$GH_TOKEN` in place of the
placeholder, so it runs with your own token), as HTTP, or just the body.
It is kept in memory, never written to disk.

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
  inotify-tools, tmux, Bash and bash-completion.
- **Everything else through mise.** It is installed at build time into
  `/usr/local/share/mise` using `mise install --system` and
  `mise reshim --system`, with the versions in `/etc/mise/config.toml`:
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
    - The shims of both directories are on `PATH`, restored by the profile
      even after a login shell resets it. A plain `bash -c` and Zed's login
      shell probe both find the tools. mise recognises the baked versions as
      system installs, so it reuses them with an empty runtime cache.
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
- **Build check:** after installing the tools, the default recipe checks
  mise with an empty runtime data directory. It fails if any configured
  version would need installing, or if the expected tool commands, Hex,
  Java, Python or Node are unavailable.

### Remote shell and upgrades

- MDT creates the VM with `msb create --shell /bin/bash`. Microsandbox's
  SSH bridge otherwise defaults to `/bin/sh`, independently of the image's
  `CMD` and root's login shell. Setting `SHELL` alone is insufficient.
- MDT also sets `SHELL=/bin/bash` in the image. The Zed sandbox profile
  explicitly selects `/bin/bash --login` for terminals.
- System Bash startup loads `/mnt/mdt/bashrc.sh`: tool paths, completion,
  an `mdt:<directory>` prompt and append-only history in Home. No dotfiles
  need to exist in a new Home; users can override defaults in `~/.bashrc`.
- `~/.local/bin`, runtime package-manager binaries and the image's rustup
  proxies are also on PATH. The shell profile is silent for SSH probes and
  works under `sh`; interactive preferences are loaded only by Bash.
- Project version files still take precedence. Run `mise install` once in
  a project before its build commands. Installing a different Elixir
  version may also need `mix local.hex --force` and `mix local.rebar --force`.

Saved Containerfiles are preserved when MDT updates. An older VM does not
acquire the current defaults automatically. In **Agent Sandbox → Settings**:

1. Review the saved recipe and any customizations. Choose **Start from MDT's
   default** to adopt the current tools, then **Save**.
2. **Build** the image. Building alone does not change a running VM.
3. **Recreate** the VM, keeping Home and Cache if desired. A stop/start
   still runs the same image. Reconnect Zed afterwards.

The overview shows the VM's actual image separately from the next image
selected for recreation. Changing the configured SSH shell also marks an
existing VM as needing recreation.

Inside-VM audit on 2026-11-12: this session was still running the earlier
Debian 12/Node image. Bash existed, but the baked mise tools and
`/etc/mise/config.toml` did not; only Erlang/Elixir installed at runtime were
in Cache, and login shells hid their shims. The shared folders were
`/home/oliveigah/projects/mdt` and `/home/oliveigah/projects/msb_test`.
Home, Cache, the VM's OptMem and the read-only MDT inbox were mounted.
There were no grants. Public package downloads worked; host files outside
the shares, host logins and host podman/msb controls were unavailable.
This audit describes that older VM, not the contents of a newly built image.

### MDT's layer

The layer holds only pointers into `/mnt/mdt`. So one image serves any
identity, the CA can change without a rebuild, and old tags keep working
with a newer MDT.

- `/etc/ssl/certs/ca-certificates.crt` links to `/mnt/mdt/ca-bundle.pem`:
  this machine's trusted roots plus the identity's CA.
    - A hook in `/etc/ca-certificates/update.d` puts the link back if a package
      regenerates the bundle.
    - The per-tool CA variables point at the same file.
- `/etc/profile.d/mdt.sh` links to `/mnt/mdt/profile.sh`, which restores tool
  paths and reads `env.sh`. `BASH_ENV` points at it too, so every `bash -c`
  reads it. `/etc/bash.bashrc` loads `/mnt/mdt/bashrc.sh` for interactive
  shells.
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

|       | In the VM | Holds                                                                                            | If lost             |
| ----- | --------- | ------------------------------------------------------------------------------------------------ | ------------------- |
| Home  | `/root`   | Codex and Claude logins, shell history, Zed's server, agent settings, your mise config           | log in again        |
| Cache | `/cache`  | versions installed at runtime (`MISE_DATA_DIR`); hex/mix, npm/pnpm, cargo, go, uv and pip caches | slower first builds |

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
  is missing, they find the grant with `mdt grants` and ask with
  `mdt request`, or describe what's missing with `--need`.
- Even with a grant on, each use waits for your approval.
- What MDT's answers mean: the `mdt_*` error codes, and requests held for
  your approval.
- `/mnt/mdt/grants.md`, rewritten on every change, holds what `mdt grants`
  prints: each grant's id, what it is for, how to use it, and its state.
- The OptMem block.
- mise: run `mise install` in a project first.

## Agent channel

MDT listens on a Unix socket per identity,
`$XDG_RUNTIME_DIR/mdt/mdt-sandbox-<id>.sock` (Unix socket paths are short,
so not the identity's folder), which `msb create --vsock <socket>:5000`
joins to the VM's vsock port 5000. The VM has no network route to the host.
Microsandbox opens the socket for each connection, so when MDT restarts,
the channel works again without touching the VM. While MDT is locked or
closed, the VM gets "connection refused".

Agents use it through `/mnt/mdt/bin/mdt`, a Bash script that talks with
socat (in the default image). It is on every shell's `PATH`. No agent needs
setting up: any agent or script that runs commands can use it.

```
mdt grants                                   every grant: id, what it is for, how to use it, state
mdt request GRANT --reason "…" [--minutes 60] [--wait 60]
mdt request --need "the access, and the host" --reason "…"
mdt wait ASK_ID [--wait 60]
mdt run --reason "…" -- COMMAND              see Host commands
mdt host                                     see Host commands
mdt ports                                    see Ports
```

- `request` asks you to turn a grant on, by id or name. It shows as an
  activation approval with the agent's reason, marked unverified, and who
  asked (read from the processes above `mdt`, so also a claim).
- It waits up to `--wait` seconds (60 by default) for your answer. Then it
  says the ask is still waiting, with its id, and exits 2; the agent can
  come back with `mdt wait`. The ask itself stays 30 minutes.
- An ask for a grant that doesn't exist yet (`--need`) offers "Set it up…",
  which opens the add dialog; the new grant answers it and turns on.
- Asking again for the same grant joins the waiting ask. At most ten asks
  wait at once.
- Turning the grant on yourself answers agents waiting for it.
- Exit statuses: 0 the grant is on, 1 the ask was wrong, 2 still waiting,
  3 declined or given up, 4 MDT isn't answering.

The protocol is one line of JSON in (`{"command": "request", ...}`), and
the exit status on the first line back, then text, then close. Any process
in the VM can ask; that is accepted, since all it can do is ask.

Checked on 2026-11-12 with a throwaway VM from the current image: socat
over msb's vsock held an ask for 75 s and got the answer and exit status;
with nothing listening, or no socket, `mdt` exits 4 at once.

<a id="host-commands"></a>

## Host commands

The escape hatch for anything no grant can express. An agent asks to run
one command on your machine; it runs only after you approve that exact
text, once.

It also moves work to where a value is, instead of the value to the VM. A
job that needs your SSH keys, a kubeconfig, a signing key or your VPN runs
here, and only its output goes back. That covers most of what file grants
were for. File grants stay for a process in the VM that needs a secret for
a long time, where an approval per use would be too many.

Agents are told to use a grant first: a request through a grant shows what
it does (the describers, the full request), and a shell line shows only
its text.

### Asking

```
mdt host                                       your machine, as agents see it
mdt run --reason "…" [--dir DIR] [--timeout 120] [--wait 60] -- COMMAND [ARG…]
mdt run --reason "…" [options] <<'EOF'         the script from stdin
…
EOF
mdt wait RUN_ID [--wait 60]
```

- **The script travels in the ask.** Arguments after `--` are quoted for
  the shell and joined; a single argument is taken as a shell line as it
  is. With no arguments, the script is read from stdin. At most 16 KiB.
  What you read on the card is what runs. A script in a file the VM can
  write could change between your click and the run, so
  `mdt run -- ./deploy.sh` is flagged.
- **Where it runs:** `--dir`, by default the agent's current directory.
  Shared folders sit at the same path on both sides, so a directory inside
  one is used as it is, after resolving symlinks on the host. A directory
  that isn't in a share, or whose real path leaves it, falls back to your
  home folder, and the card says so.
- **Time limit:** `--timeout`, 1 to 3600 seconds, 120 by default.
- The same script, directory and limit as an ask already waiting joins it.
  At most ten wait at once.
- Like grant asks, the agent waits up to `--wait` seconds (60 by default),
  then hears the ask is still pending and comes back with `mdt wait`. The
  ask waits 30 minutes for you.

### Approving

A command is an approval of its own kind, in the same queue, drawn apart
from the others (red, a terminal icon):

- **Facts:** the script in full, with a copy button; where it runs, and
  whether the VM can write there; the time limit; who it runs as.
- **Hints,** worked out from the script's text and marked as hints, not a
  review: it runs build tools, scripts or git in a folder the VM can write;
  it names files the VM can write; it downloads code and runs it; it uses
  `sudo`; a grant already covers a host or tool it uses.
- **The agent's reason,** as a claim.
- **Choices:** run it, with the output sent straight back or shown to you
  first; or decline. No "allow similar", no "allow every use": each command
  runs once, as you, outside the VM.

### Running

- `bash -lc SCRIPT` as you, in the directory, with stdin from `/dev/null`,
  under `timeout`: TERM at the limit, KILL 5 seconds later, to its whole
  process group.
- The environment is MDT's own, without MDT's and the BEAM's variables
  (`RELEASE_*`, `ERL_*`, `MIX_*`, `PHX_*`, `MDT_*`, `SECRET_KEY_BASE`,
  `PORT`…). The login shell then sets up your usual tools. SIGPIPE, which
  the BEAM ignores, is back to its default (`env --default-signal`, where
  `env` has it), so `cmd | head` ends quietly, as in a terminal.
- Output, stdout and stderr together, keeps its first and last 32 KiB.
  What's between is cut, and the agent is told how much.
- Running commands show at the top of the approvals page with a Stop
  button, which kills the process group. Locking or quitting MDT stops them
  too.
- **Output shown first:** when the command ends, its card comes back to
  the queue with the exit status and the output, to send or keep. Not
  deciding within 30 minutes keeps it.
- On the overview a waiting command can be declined, but running it takes
  the full card, so the script is always read in full first.
- The output stays in memory with the approval (the latest 100 decisions)
  and is never written to disk. The activity log records the ask's fate
  and the exit status, never the output; crash reports leave it out too.
- Some versions of `timeout` exit 124 when stopped from outside as well, so
  MDT counts a run as timed out only when it lasted its whole limit, and
  tells the agent when you stopped it.

### What the agent hears

`mdt run` (and `mdt wait` on a run) exits with the command's own status
when it ran and its output came back: 124 when it hit the time limit, as
with `timeout`. MDT's own outcomes use codes commands rarely use, with a
line on stderr saying which:

| Status | Meaning                                                    |
| ------ | ---------------------------------------------------------- |
| 120    | Still waiting for you. Come back with `mdt wait RUN_ID`.    |
| 121    | It didn't run, or its output didn't come back: declined, not answered in 30 minutes, couldn't start, or you kept the output. |
| 122    | The ask was wrong.                                         |
| 123    | MDT isn't answering: locked or closed.                     |

### Checked

Built and tried on 2026-11-12, from inside the VM, against MDT's dev server
running there (no KVM in the VM, so no nested VM): the real `mdt` command
and socat on the channel socket; `mdt host` with the tools found and your
notes; a run with the output sent straight back; a script from stdin with
the output shown first, then kept (the agent got 121 and no output); a long
run stopped from the overview (the output so far came back, no process
left); a decline. Not yet tried through a real VM's vsock, which carries
the same bytes as the `grants` and `request` asks already checked there.

### Your machine, as agents see it

`mdt host` prints, and `/mnt/mdt/host.md` holds: OS and version,
architecture, kernel, login shell, home folder, the shared folders and
their modes, and which of a fixed list of command-line tools are on your
login shell's `PATH`, with their versions. Then the VM's address on your
machine (see [Ports](#ports)) and your own notes about the machine, from
Settings. MDT collects it when it unlocks, and when you ask from Settings;
agents never probe the host to find out.

## Ports

A server an agent starts in the VM shows up on your machine by itself. A
Phoenix server on port 4000 in the VM is `http://127.77.12.34:4000` here
within a few seconds, and goes away when it stops.

### The address

- Each identity's VM has a fixed address on your machine, `127.77.X.Y`,
  derived from the identity. Linux sends all of `127.0.0.0/8` to loopback,
  so it needs no setup. Ports keep their numbers without colliding with
  your machine's own: your `localhost:4000` stays yours.
- The overview shows the address and the ports up there. Agents learn it
  from `mdt host` (`/mnt/mdt/host.md`), and `mdt ports` lists what is
  forwarded, so they can give you the URL.
- No name for it. A name needs root once (`/etc/hosts`), and dev servers
  that check the Host header (Vite, Rails, Django) refuse unknown names but
  accept addresses. `*.localhost` names always go to `127.0.0.1`, which
  brings the collisions back.
- Browsers treat the address as a site of its own, so the VM's pages never
  see the cookies of your other local apps, and as a secure context (all of
  `127.0.0.0/8` is), so service workers and WebAuthn work.

### What is forwarded

- Every TCP port listening in the VM, read every 2 seconds with `ss -ltnpH`,
  with the process that holds it. A server on the VM's `127.0.0.1` or `::1`
  works: connections are made from inside the VM, to loopback when the
  server listens there or on every address.
- Each to the same port on the address. Listed with the reason, and not
  forwarded:
    - ports below 1024: listening on one needs root on your machine
      (`ip_unprivileged_port_start`);
    - a port your machine already holds on every address;
    - anything past 64 ports.

### How it works

- MDT keeps one SSH connection to the VM: OpenSSH as a control master,
  through `msb ssh serve VM --stdio`. msb's SSH server carries forwarded
  connections (`direct-tcpip`) over its own channel to the VM's agent, which
  connects inside the VM; the VM's network isn't involved. Forwards are
  added and removed on that connection (`ssh -O forward|cancel`), and the
  listing runs over it too.
- It uses a key of its own, made on first use in the identity's sandbox
  folder and added with `msb ssh authorize` on each start. It reads no
  `~/.ssh/config` (`-F /dev/null`) and never prompts (`BatchMode`).
- It runs while the VM runs. If the connection drops, MDT connects again
  every few seconds. Stopping the VM, locking MDT or quitting it ends the
  connection, and its forwards with it; if MDT dies, a wrapper ends ssh.
- Not msb's own published ports (`--port`): each new one needs a restart,
  and they arrive on the VM's network interface, so servers on the VM's
  loopback can't be reached.

### Safety

- Connections go one way, from your machine into the VM. Nothing new
  reaches your machine from the VM.
- Forwards listen on the VM's address only, never on every address, so
  other machines can't reach them.
- As with any local dev server, any program on your machine can connect,
  and a VM page in your browser is untrusted content, like a website. MDT's
  own pages stay out of its reach: their session cookie is
  `SameSite=Strict`, the endpoint checks origins, and LiveView needs a token
  from MDT's own page. The desktop app's webview doesn't share your
  browser's cookies anyway.
- MDT's key opens SSH to every VM in MDT's microsandbox home (every
  identity's on this machine), since msb keeps one list of keys per home.
  VMs of an `msb` you run yourself keep their own list. The key is as
  sensitive as the keys in `~/.ssh`, and sits in the identity's folder,
  readable by you only. Anything running as you can already run `msb exec`.

## VM

- **Checks:** KVM is available, MDT's `msb` is there (see
  [Runtime](#runtime)), the image exists.
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
    - `--vsock` for the agent channel;
    - CPU and memory limits;
    - `--root-disk` and a `quota=` on every read-write mount (see Disk).
- **Disk:** two settings, both applied by recreating.
    - *Root disk* (64 GiB): what the image and the VM write outside its
      folders, apt packages, `/tmp` and `/var` included. A sparse ext4
      image, so it takes host space only as it fills; it starts empty on
      every recreate. microsandbox's default is 4 GiB.
    - *Folder writes* (64 GiB): how much the VM may add to each read-write
      folder (Home, Cache, OptMem, shares) per boot, beyond what was there
      at its first write. Past it, writes fail with `ENOSPC`, and `df` in the
      VM shows the budget, not your disk. It keeps a runaway agent from
      filling your disk. microsandbox applies 4 GiB to every mount unless
      told otherwise; read-only folders get none.
    - Checked on the host: `--root-disk 64G` and `quota=64G` showed 62.9G
      and 64G free in the VM.
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

### Runtime

MDT brings its own microsandbox; nothing needs installing on the machine.

- **What ships:** `msb` v0.7.14 built from source with MDT's
  [live-sharing patch](../priv/sandbox/microsandbox-live-sharing.md), and
  that release's `libkrunfw.so.5.6.1` (the guest kernel). The patch is why
  it isn't the stock release: without it, git in the VM can see an empty
  index after the host replaces it (see the blocker below).
- **Built by** `scripts/build-microsandbox.sh` into `priv/microsandbox`
  (`bin/msb`, `lib/libkrunfw.so.5.6.1`), so the release carries it and
  `msb` finds its kernel beside `bin/`. Everything is pinned there: the
  source revision, and the SHA-256 of the guest agent (embedded in `msb`)
  and of `libkrunfw`. The package build runs it once, on Ubuntu 22.04, the
  older glibc of the two packages; `msb` links only glibc. In a source
  checkout, run it once yourself.
- **Its own home:** VMs, images and msb's SSH keys live in
  `~/.mdt_client/microsandbox` (`MSB_HOME`), not `~/.microsandbox`. An
  `msb` you install, at any version, neither sees MDT's VMs nor migrates
  their database. Every call also sets `MSB_PATH`, the binary VMs are
  spawned with.
- **Launcher:** `~/.mdt_client/bin/msb` runs MDT's `msb` with that home.
  The Zed SSH config uses it, and so can you (`~/.mdt_client/bin/msb ls`).
  MDT rewrites it on start, so its path survives an update that moves the
  runtime.
- **Never** the `msb` on your PATH: MDT has no fallback to it.
- **Upgrading microsandbox** means changing the pins in the script and
  checking the patch still applies. A VM keeps running on the binary it
  started with until it is stopped.

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
  of a shared repo coordinates writes. This does not establish read coherence;
  see the blocker below.

#### Shared-folder correctness blocker (2026-11-12)

Live host/VM testing found a coherence defect in the current microsandbox
virtiofs setup. After the host atomically replaces a file, the VM can report
`ENOENT` while the replacement exists on the host. All 100 host-side Git
index replacements in the probe made `git ls-files` inside the VM report
zero tracked files. A fresh host-created index was readable initially, and
the final index became readable later with all 64 expected entries and a
valid checksum. The tested file contents were intact after recovery.

The probe also received no guest-side inotify mutation events for host
creates, overwrites, replacements, deletes or recreates. Events caused by
the guest's own reads were excluded. This can leave an editor's Git view
stale even after the file becomes readable again. Running `git status`
cleared the red Zed tree that led to this investigation.

VM-only atomic replacements, Git index replacements and notifications
passed. Host reads of VM writes and exclusive creates held on either side
also passed. These results narrow the failure to host-to-VM coherence and
notifications. The patched runtime was subsequently validated as described below.

Microsandbox v0.7.14's directory mount backend inherits five-second entry
and attribute caches. Its mount options expose no cache override.

A [local runtime patch](../priv/sandbox/microsandbox-live-sharing.md) now
retains those normal metadata caches and returns `ESTALE` for stale Linux
inode references so the guest can retry lookup. The earlier zero-timeout
variant was removed after a resource sample measured about 5.8 host CPU cores
in the VM process. The candidate is now built with release optimizations.
It retains buffered I/O, open handles and hard-link aliases. All 680
filesystem unit tests passed with the patch, including five new regressions;
the two new stale-reference regressions failed against the original code.
The earlier uncached CLI compiled. After host installation and a VM restart, the
cross-host probe passed with zero failures, including all 100 host-side Git
index replacements, file create/overwrite/replace/delete/recreate, and
exclusive creates in both directions. Evidence:
`tmp/sandbox-sharing-probes/cross-j1wi5zdm/cross-results.json`.

MDT's image environment and shell profile now explicitly choose Zed polling
(`ZED_FILE_WATCHER_MODE=poll`, `ZED_FILE_WATCHER_POLL_MS=5000`). This handles
editor refresh without guest inotify mutation events; other file watchers
need their own polling configuration or validation. The earlier variant
passed content/index/lock checks and the user confirmed automatic Zed
refresh.

MDT now ships the patched runtime itself (see [Runtime](#runtime)), built
by `scripts/build-microsandbox.sh`. Rerun the cross-host check after
changing it. With the VM running, one host command runs both halves of the
content/index/lock check (its `--msb` defaults to MDT's launcher):

```sh
python3 scripts/sandbox_shared_fs_probe.py check --sandbox SANDBOX_NAME
```

Reproducer: `tmp/agent_sandbox_spikes/shared_fs_probe.py` (disposable files
and repositories only). Evidence: `cross-ewcmtt58/cross-results.json` and
`cross-ewcmtt58/recovery-results.json` alongside it. These diagnostic files
are gitignored. Upstream code:
[cache defaults](https://github.com/superradcompany/microsandbox/blob/v0.7.14/crates/filesystem/lib/backends/passthroughfs/unix/mod.rs#L560),
[inode reopening](https://github.com/superradcompany/microsandbox/blob/v0.7.14/crates/filesystem/lib/backends/passthroughfs/unix/inode.rs#L568),
[mount options](https://github.com/superradcompany/microsandbox/blob/v0.7.14/crates/runtime/lib/runner/vm.rs#L3652).

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

- **Encrypted, like other MDT data:** grants, stored values, allowances, VM
  settings, MDT's CA key, the activity log.
- **Plaintext, readable by the VM:** `/mnt/mdt` (holds no real values except
  file grants), the VM's OptMem, Home and Cache. Home holds the VM's own
  logins (Codex, Claude). Its snapshots sit next to it, readable by MDT
  only. On this machine the disk itself is encrypted.

Shared by every identity on the machine, not encrypted: MDT's microsandbox
home (`~/.mdt_client/microsandbox`: VMs, images, msb's SSH keys) and the
launcher (`~/.mdt_client/bin/msb`).

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
    - waiting approvals of both types;
    - grants that are on, with time left;
    - the VM's address on this machine and the ports forwarded there, as
      links, with those that aren't and why.
- **Grants:**
    - the list, each with what it is for, a switch and duration choices
      (15 min, 1 h, 4 h, until turned off);
    - adding a grant: a type, or a preset that fills the form;
    - per grant: what the VM gets, "allow every use for…", its allowances,
      its own activity.
- **Approvals:** waiting cards of all three types, with facts and the
  agent's claims kept apart, and held requests in full with copy buttons;
  commands running on this machine above them, with Stop; history below,
  where a command opens to its script and output.
- **Activity:** the log, filterable by grant, host and outcome.
- **Settings:** image, CPU and memory, shared folders, private ranges, and
  this machine as agents see it, with your notes for them.
  Changing folders, network or vsock recreates the VM; MDT says so before
  applying.

Approvals and agent requests raise a desktop notification. This needs
`tauri-plugin-notification`, which MDT's shell does not include yet.

## Components

Each has one job. Proposed modules sit under `lib/mdt_client/sandbox/`.

| Component              | Job                                                                                    |
| ---------------------- | -------------------------------------------------------------------------------------- |
| `VM`                   | Turns settings into `msb` commands, starts, stops, reports status                      |
| `Settings`             | VM settings for the identity, and what needs a restart                                 |
| `Shares`               | Validates folder picks, produces mounts                                                |
| `Inbox`                | Writes `/mnt/mdt` atomically: CA certificate, `env.sh`, credential helper, file grants |
| `CertificateAuthority` | Creates the CA, makes and caches a certificate per host                                |
| `Grants`               | Grants, their state and expiry; the source of truth                                    |
| `Presets`              | The three types and the presets that fill their form                                   |
| `Credentials`          | Returns the value for a grant: stored or minted, with caching                          |
| `Egress.Listener`      | Accepts msb's CONNECTs (Thousand Island, already a dependency through Bandit)          |
| `Egress.Destination`   | Deny, private-range gate, intercept or tunnel                                          |
| `Egress.Tunnel`        | Moves bytes both ways and counts them                                                  |
| `Egress.Interceptor`   | TLS, HTTP/1.1, holding, forwarding (Mint, already a dependency)                        |
| `Egress.Substitution`  | Finds placeholders in carriers and swaps them, including Basic auth                    |
| `Allowance`            | What goes through without asking, and until when                                       |
| `Describe`             | Turns requests into facts                                                              |
| `RequestView`          | Shows a held request in full, and as curl or HTTP to copy                              |
| `Approvals`            | Waiting requests and connections, timeouts, decisions, PubSub                          |
| `Activity`             | The append-only log                                                                    |
| `Channel`              | The vsock socket behind the `mdt` command                                              |
| `HostCommand`          | Checks an ask to run a command and describes it: where it runs, facts, hints           |
| `HostRun`              | Runs an approved command on the host: time limit, capped output, process group         |
| `HostInfo`             | What agents are told about this machine (`mdt host`, `host.md`)                        |
| `Ports`                | The VM's address here; reads `ss` and decides what to forward, and why not             |
| `Forwarder`            | Keeps the SSH connection to a running VM and its forwards in step with the VM's ports  |
| `VMMemory`             | The OptMem folder and its Transfer participant                                         |

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
   reading the grants (never values), the host's description and the
   forwarded ports, asking for a grant, and asking to run a command.
8. Nothing in the VM can approve its own requests.
9. Nothing runs on the host for the VM without your approval of its exact
   text, each time. What runs is the text on the card.
10. Forwarding opens nothing from the VM to your machine, and listens only on
    the VM's own loopback address.

## Checks (2026-11-11)

These ran on Fedora 44 with msb 0.7.14. They used a throwaway proxy in plain
OTP and stock images (`python:3.12-slim-bookworm`, `elixir:1.18-slim`,
`google-cloud-cli:slim`). No real credentials were used: each placeholder was
swapped for an invalid value, and each provider's rejection showed that the
swapped value reached it. Scripts and logs are in
`tmp/agent_sandbox_spikes/` (gitignored).

| #   | Check                                                       | Result                                                                                                                                                                                                                                                    |
| --- | ----------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | VM's own ClientHello reaches MDT                            | **Yes.** Without `--tls-intercept`, microsandbox does not decrypt. The VM saw the real certificate. CONNECT carries only the IP, and SNI is readable.                                                                                                     |
| 1   | Proxy kept across stop, start and `msb ssh` boots           | **Yes.** It's saved as `outbound_proxy`. A VM booted by `msb ssh` with MDT down has no internet.                                                                                                                                                          |
| 1   | Plain HTTP, port 22, private ranges, the host's LAN address | All arrive at the proxy as CONNECT.                                                                                                                                                                                                                       |
| 1   | `host.microsandbox.internal`, the VM's own `127.0.0.1`      | Refused. Neither reaches the proxy.                                                                                                                                                                                                                       |
| 1   | Non-DNS UDP                                                 | Blocked (NTP query timed out).                                                                                                                                                                                                                            |
| 1   | DNS                                                         | Goes to microsandbox's resolver, then the host's systemd-resolved (`_gateway` resolved to the router). Private-address answers pass. Port 53 to any address is answered too.                                                                              |
| 2   | TLS termination in Elixir                                   | `:gen_tcp.unrecv/2` with the peeked bytes, then `:ssl.handshake/3`, works. Offering only HTTP/1.1 made curl drop h2.                                                                                                                                      |
| 2   | Carriers                                                    | `gh`: `Authorization: token <ph>`, including `POST /graphql`. git: anonymous first, then Basic with the placeholder as password after the 401. Hex: the whole `Authorization` value, no scheme. gcloud: `Bearer`. All four swapped and rejected upstream. |
| 2   | CA trust                                                    | System store is enough for curl, git and `gh`. Hex needs `HEX_CACERTS_PATH`. gcloud needs `CLOUDSDK_CORE_CUSTOM_CA_CERTS_FILE`. Erlang needs `ca-certificates` installed.                                                                                 |
| 2   | 180-second hold                                             | `gh`, git and gcloud wait. Hex gives up after 15 seconds and retries twice; with `HEX_HTTP_TIMEOUT=300` it waits. gcloud retried once after the 401.                                                                                                      |
| 3   | VPN                                                         | **Not run: no VPN on this machine.** Covered so far: DNS reaches systemd-resolved (where NetworkManager registers VPN domains), and private destinations go through the proxy. Still to do: resolving a VPN name and reaching a VPN host while connected. |
| 4   | Same-path mounts                                            | Work.                                                                                                                                                                                                                                                     |
| 4   | Read-only                                                   | Enforced by the host, even after a remount inside the VM.                                                                                                                                                                                                 |
| 4   | Read-only inside read-write                                 | **Not safe.** Unmounting it exposed the host folder underneath, which was writable.                                                                                                                                                                       |
| 4   | Changing mounts live                                        | **Not possible.** `msb modify` has no mount option, and `msb restore` has no `--proxy`.                                                                                                                                                                   |
| 5   | vsock to a host Unix socket                                 | Works both ways. Survives the host server restarting. "Connection reset" while it's down.                                                                                                                                                                 |
| 6   | OptMem in the VM                                            | `init`, `note`, `wake` work. `flock` does not cross host and VM; `O_EXCL` does.                                                                                                                                                                           |

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
- The agent channel as an MCP server too, on the same socket.
- Rules on top of allowances, if asking about every use proves too much:
  per method or path, or per provider where a describer knows the API.
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
