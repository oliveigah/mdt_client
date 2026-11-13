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

Planned (2026-11-13): the first release for other people. msb starts
confined, work moves to the VM's own disks, host commands become a grant,
and DNS goes through MDT. See [First release](#first-release), whose
[order of work](#order-of-work) says which steps are built: the first
five of seven, uncommitted on the `sandbox-review` branch. Sections further
down that those steps changed say so where they start.

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
- **Code you run on the host from a folder shared read-write.** A VM can
  plant git hooks, `core.fsmonitor` in `.git/config`, build scripts. Running
  git, mix or npm on that folder on the host runs them. MDT's own Git tool
  does this too, and so does a host command you approve there; its card
  says so when it can tell, but the hints are not a review. Folders are
  shared read-only unless you confirm a warning that says this, and the
  VM's own work sits on its disks, which nothing on the host opens.
- **File grants after they are handed over.** See [Grant kinds](#grant-kinds).
- **Data sent out through DNS.** Every lookup goes through MDT and is in
  the activity log, and a query aimed at another resolver gets no answer.
  But MDT answers every name, so query names can still carry data out.
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
| 2026-11-13 | Port forwarding from the VM is dropped for now. What was built, and the options, are in `docs/todo.md`.                                                          |
| 2026-11-13 | MDT ships its own msb (v0.7.14 with the live-sharing patch, and its libkrunfw) and keeps its state in its own microsandbox home. An `msb` you install is never used. Now built from the fork (below). |
| 2026-11-13 | `msb` is built from MDT's fork (oliveigah/microsandbox, commit `6626e7cb2`: v0.7.15 plus the ESTALE fix) until upstream takes the fix. Replaces the patch file. |
| 2026-11-13 | Disk is a setting: the root disk (64 GiB, sparse) and a write budget per read-write folder per boot (64 GiB), instead of microsandbox's silent 4 GiB for both. |
| 2026-11-13 | The first release has one VM backend, microsandbox. A second (stock VMM parts, spiked in `test/review/vm_spike`) is decided after it. macOS is not a target for now. |
| 2026-11-13 | msb runs inside a bubble (`bwrap`): namespaces of its own, no home folder, no network. Its proxy and DNS reach MDT over Unix sockets. |
| 2026-11-13 | DNS goes through MDT, which logs every name. Supersedes "DNS never goes through MDT"; names can still carry data out. |
| 2026-11-13 | Work lives on the VM's own disks: Home, Cache and Work are disk images. Supersedes Home and Cache as host folders (11-12). |
| 2026-11-13 | Host folders are still shared one by one, but as the exception: read-only unless you confirm a warning. Narrows the 11-11 decision. |
| 2026-11-13 | A project is a copy of your repository in the VM, not a shared folder. Your branches reach it by sync, as `host/…`, through git over msb's pipe. Shared folders are for what isn't a repository. |
| 2026-11-13 | The VM's work comes back only as handoffs: a finished piece of work an agent names and describes, fixed to one commit, like a pull request. You review it whole. |
| 2026-11-13 | Your branches are yours. MDT never commits, stages, or creates, moves or deletes a branch of yours. A handoff you accept arrives in your working tree uncommitted; committing is yours to do. |
| 2026-11-13 | MDT never writes into storage the VM can write. What it has for the VM goes through `/mnt/mdt`; the VM copies what it needs itself. |
| 2026-11-13 | Host commands are a grant type, `command`. No such grant exists until you add one, so a new install runs nothing on the host for the VM. Every run still waits for approval. |
| 2026-11-13 | The image is built on your machine with podman, from the recipe MDT ships. Nothing is published to a registry for now, so podman is required. |
| 2026-11-13 | The MDT you use every day is the installed package. It loads no code from a folder a VM can write. Agents developing MDT work in the VM and hand over a branch. |
| 2026-11-13 | Whether a use goes through, asks or is refused is one pure function of the grants, the use and the clock (`Policy.decide/3`). The server acts on its answer and decides nothing itself. |
| 2026-11-13 | Text the VM chooses is shown with all it holds. Bytes that aren't UTF-8 and characters that don't show are written out where the text enters MDT. A script for your machine that hides anything is refused, not shown changed. |
| 2026-11-13 | Intercepted hosts keep MDT's own strict reader for the first release. Bandit and Finch were tried and not taken (see [step 5](#step-5)). Narrows the plan made the same day. |
| 2026-11-13 | On Ubuntu the bubble is made with MDT's own copy of the system's bwrap, at `/usr/lib/mdt/bwrap`, under an AppArmor profile the deb installs: what runs inside may hold the two capabilities the relay uses, and no other. See [step 6](#step-6). |
| 2026-11-13 | The folders above msb's store are yours alone (`0700`), whatever umask made them. |
| 2026-11-13 | Every VM says which it is: MDT records an id for each VM it creates, the VM gets it at boot, and `mdt vm` and every login shell say whether this is the VM MDT runs. The Setup page warns when `~/.ssh/config` reaches the VM through anything but this identity's launcher. |

<a id="first-release"></a>

## First release

Decided 2026-11-13; nothing here is built. It is the plan for the first MDT
release that carries the Agent Sandbox to other people, on Linux. Where it
disagrees with a later section, that section says what runs today and this
one what it becomes. Each step below updates the sections it changes.

### Who it defends against

Whatever runs in the VM, as root: an agent following instructions planted
in a web page or a repository, or a package it installed. It can do
anything inside the VM, and send any bytes to the three things MDT offers
it: the proxy, DNS and the agent channel.

- It is not assumed to hold a working exploit against KVM or microsandbox.
  If it does, [the bubble](#the-bubble) decides what it reaches.
- Not defended: what you approve; leaks of what you gave the VM (see
  [Not covered by v1](#not-covered-by-v1)); other programs running as you.

### Promises

| Promise                                                         | Kept by                                                                                                               |
| --------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------- |
| The VM never holds a credential (file grants excepted, labeled) | Placeholders, swapped by the proxy                                                                                    |
| Nothing leaves the VM except through MDT, DNS included          | The process running the VM has no network; its ways out are MDT's sockets                                             |
| Nothing the VM writes runs on your machine unless you chose it  | The VM's work reaches your files only as a handoff you accepted, uncommitted; shares read-only unless you confirm; no command grant until you add one |
| A VM escape reaches no home folder and no network               | The bubble                                                                                                            |
| An approval shows what will happen, with nothing hidden in it   | Facts MDT works out itself, the agent's words kept apart, and text that is written out wherever it hides something ([Text the VM chooses](#text-the-vm-chooses)) |

Each is a numbered line in [Guarantees to test](#guarantees-to-test),
checked by a test on a real VM before a release.

<a id="the-bubble"></a>

### The VM runs in a bubble

Today the process running the VM (`msb machine`) is an ordinary process of
yours: it sees `~/.ssh` and the docker socket, has your machine's network,
and no seccomp filter. MDT will start it with `bwrap` (bubblewrap, which
Flatpak uses; a package dependency) instead:

```
bubble: own user, mount, network, PID, IPC, UTS and cgroup namespaces
  /usr read-only; msb's runtime read-only; no /run; only `lo`
  of /home, nothing but the path to msb's own store
  read-write: this identity's microsandbox home, its disks, its shares

  msb ── 127.0.0.1:3128 ────────▶ relay ──▶ proxy.sock ──▶ MDT egress proxy
  msb ── 127.0.0.1:5353 (DNS) ──▶ relay ──▶ dns.sock ───▶ MDT DNS forwarder
  msb ── vsock 5000 ───────────────────────▶ channel.sock ▶ MDT agent channel
```

- **Sockets:** one folder per identity, `$XDG_RUNTIME_DIR/mdt/<id>/`, mode
  0700: `proxy.sock`, `dns.sock`, `channel.sock` and `control.sock`. The
  proxy no longer listens on a loopback port, so the port setting goes
  away, and no other program on the machine can use it as a proxy.
- **msb is told** `--proxy http://127.0.0.1:3128` and
  `--dns-nameserver 127.0.0.1:5353`. Those ports exist only inside the
  bubble; every identity's bubble has its own.
- **The relay** (`native/mdt_relay`, Rust, no dependencies, built to
  `bin/mdt-relay` beside `msb`) is the bubble's first process. It does five
  things:
    1. adds a default route into loopback, then gives up its capabilities
       for good. msb gives the VM an IPv4 address only when the kernel can
       pick a route to a public address (`host_has_ipv4_route`,
       `crates/network/lib/engine/network.rs`); this route leads nowhere;
    2. joins the two loopback ports to the two sockets;
    3. runs the `msb create` or `msb start` MDT gave it, and writes how
       that went to `start.out`;
    4. answers `control.sock`: `status`, and `stop`, which runs `msb stop`
       and then exits;
    5. exits when the VM's process ends.
- **The VM runs exactly as long as the relay does.** The relay is process
  1 of the bubble's PID namespace (`bwrap --as-pid-1`), so when it ends,
  however that happens, the kernel ends everything else in there. bwrap's
  own first process doesn't do that: in the check, with it, a killed relay
  left the VM running with nothing to stop it.
- **One relay per VM.** It holds `relay.lock`; a second one for the same
  sockets refuses to start, rather than take over the first one's control
  socket.
- **Everything the VM is made of sits under `/mdt`,** a path that exists
  only in the bubble: `/mdt/runtime`, `/mdt/sockets`, `/mdt/disks`,
  `/mdt/inbox`, `/mdt/optmem`, `/mdt/shares/N`. msb boots a stopped VM by
  itself on `exec` and `ssh`, and has no switch for that. Outside the
  bubble it can't boot this one: its disks aren't there ("disk image host
  path does not exist: /mdt/disks/work.img").
- **Stopping and status go through the relay.** msb records the VM's
  process id as the bubble sees it, so `msb stop` fails from outside, and
  what it says about a VM running means nothing there. `msb exec`, and so
  MDT's own calls into a running VM, work from outside: they go through
  sockets in the microsandbox home.
- **MDT crashing leaves the bubble running**, with no internet until MDT
  listens again: it is started detached (`setsid`), tied to nothing. MDT
  finds it through `control.sock` when it comes back. Quitting or locking
  stops the VM cleanly, as before.
- **DNS:** MDT's forwarder (`MDTClient.Sandbox.Dns`) reads each query's
  name and type, logs them in the activity log (a name again only after 10
  minutes), passes the query to this machine's resolver (so VPN names keep
  working) and returns the answer unchanged. A query the VM aims at another
  resolver gets no answer, since msb has no network to send it.
- **The microsandbox home is per identity**
  (`~/.mdt_client/identities/<id>/sandbox/microsandbox`), so one identity's
  bubble never holds another's VM. Cost: the image is stored once per
  identity. msb is given a short link to it as its home, beside the
  sockets: it keeps Unix sockets of its own about 60 bytes below its home,
  and a socket's path must fit in 108. The bubble has the folder at both
  paths, since msb records its images by the real one.
- **The launcher** is per identity too (`…/sandbox/bin/msb`, used by Zed).
  It only looks at the VM and goes into it: `exec`, `ssh` and `cp` are
  refused while the VM isn't running (nobody holds `relay.lock`), and what
  starts, stops or changes a VM is refused always. It says to use MDT.
- **What the machine lacks** is said on the Setup page and when you start
  the VM: `bwrap` missing or not allowed to create user namespaces, the
  relay missing from the build, `mkfs.ext4` and friends missing.

Checked on 2026-11-13 with a throwaway VM (msb 0.7.14, Alpine), the bubble
beside plain msb. The relay was a Python script then; the Rust one passes
the same rows, and more (below).

| Check                                      | Plain msb                      | In the bubble                              |
| ------------------------------------------ | ------------------------------ | ------------------------------------------ |
| The VM's process sees `/home`, docker's socket | Yes                        | No                                         |
| Its network                                | This machine's (Wi-Fi, docker) | `lo` only                                  |
| Namespaces of its own                      | None                           | All seven                                  |
| `NoNewPrivs`, capabilities                 | 0, none                        | 1, none                                    |
| HTTP and HTTPS from the VM                 | Through the proxy              | Through the proxy, over the socket         |
| DNS names the host side saw                | None                           | Every name                                 |
| `nslookup name 8.8.8.8` in the VM          | Answered, unseen               | No answer                                  |
| Proxy socket removed                       | Not applicable                 | "Connection refused"                       |
| `msb exec` from outside, a shared folder   | Work                           | Work                                       |
| Create and boot                            | 0.4 s                          | 0.7 s                                      |

Scripts and output: `test/review/msb_confine` on the `sandbox-review`
branch (`run.py`, `inside.py`, `results/`).

### Storage: the VM's own disks

Three ext4 disk images per identity, in `~/.mdt_client/<id>/sandbox/disks`,
sparse, attached with `--mount-disk`:

| Disk  | In the VM | Holds                                               | Default size | Recreating                                |
| ----- | --------- | --------------------------------------------------- | ------------ | ----------------------------------------- |
| Home  | `/root`   | Agent logins and settings, shell history            | 16 GiB       | Keep (default), go back to a snapshot, or start empty |
| Cache | `/cache`  | Tool versions and package caches                    | 64 GiB       | Keep (default) or clear                   |
| Work  | `/work`   | Your repositories and everything built in them      | 64 GiB       | Always kept; emptied only when you ask    |

- **Why:**
    - A folder shared read-write is the easy way out of the VM: a hook or a
      `.git/config` line the agent writes runs when you use git, mix or npm
      there. With work on a disk, nothing on the host opens it.
    - Files are faster. In one VM, creating 10,000 files took 0.85 s on a
      disk image and 3.51 s in a shared folder; reading them 0.23 s and
      1.89 s. A Python version of the same steps in your own VM gave 0.46 s
      on the root disk against 4.58 s in a share.
    - Host and VM no longer build in the same folder with different tools.
- **Made with** `mkfs.ext4 -E root_owner=0:0` on a sparse file, which
  needs no root. Sizes are settings; growing one is offered while the VM
  is stopped, shrinking isn't.
- **Snapshots:** before a recreate MDT copies `home.img` (a reflink where
  the filesystem has them, a sparse copy elsewhere), and keeps 3, as today.
- **Stops are clean.** MDT stops the VM and waits before removing it. A
  forced remove is a power cut: in the check, a file written 0.1 s before
  `msb rm --force` was gone after the recreate, while one written before a
  plain `msb stop` was there.
- **The write budget** per folder now applies only to read-write shares;
  a disk's size is its limit.
- **Not readable from the host** while the VM is stopped. Files come out
  through git, or `msb cp` while it runs.

Repositories are not shared at all: see [Projects](#projects).

**Shared host folders** stay for what isn't a repository (a dataset, a
folder of documents), one by one, at the same path as on the host:

- read-only by default;
- read-write only after you confirm a warning that says it plainly: what
  the VM writes there can run on your machine when you use that folder;
- the VM's OptMem folder stays a host folder, since MDT reads it (as data,
  while the VM is stopped).

<a id="projects"></a>

### Projects: a copy in the VM, work handed back like a pull request

A project is a git repository on your machine that you add to the VM. MDT
makes a copy of it on the Work disk, at `/work/<name>`. No folder is
shared. The two directions are different on purpose:

```
your repository                               /work/<name> in the VM
  your branches   ── sync ──▶    arrive as    host/master, host/…
  a handoff       ◀── mdt handoff ──          one finished piece of work
     you review it whole; it comes into your working tree uncommitted
```

- **Your branches are yours.** MDT never commits, never stages, and never
  creates, moves or deletes a branch of yours. Nothing from the VM lands
  on them as a commit.
- **Transport, both ways:** MDT runs git on your machine, and the other
  end of git's protocol runs in the VM through msb's pipe
  (`msb exec --stream VM -- git receive-pack /work/<name>`, and
  `upload-pack`). No network, no SSH, no share. What crosses is git
  objects, checked on arrival (`fetch.fsckObjects`), and names. No config,
  hook, index or working file crosses. MDT writes nothing into your
  repository's config.

#### Sync: your work into the VM

- Your local branches arrive in the VM as `host/<branch>`. Only committed
  work goes, unless you tick "include what I haven't committed", which
  adds a snapshot of your working tree as `host-wip/<branch>` (a commit
  made from a copy of the index, so nothing in your tree changes).
- **`/work/<name>` follows your branch.** It starts on the branch your
  checkout has. A sync fast-forwards it when it is clean and only behind
  (`receive.denyCurrentBranch=updateInstead`); otherwise the sync leaves
  it alone and says so.
- **One worktree per agent session.** Each session starts a worktree and
  a branch of its own, from your branch as it is then, and works only
  there:
  `mdt sync && git worktree add /work/<name>.wt/<task> -b <task> host/master`.
  Several sessions work side by side this way, and each handoff holds one
  session's work and nothing else. `/work/<name>` itself is nobody's
  workplace: it only follows your branch. The agents' instructions say
  so, and `mdt handoff` holds them to it (below).
- **When:** a Sync button on the project, and `mdt sync` in the VM, which
  needs no approval: it only brings your committed branches to the VM.
  There is no timer.
- **Not carried:** files git ignores (`_build`, `deps`, `.env`), so each
  side builds its own; submodules and LFS files, which the VM gets from
  their own remotes.

<a id="handoffs"></a>

#### Handoffs: the VM's work back to you

Work in progress in the VM stays in the VM. What comes back is a
handoff: one finished piece of work that an agent wraps up, names and
describes, the way it would open a pull request.

```
mdt handoff --title "Fix the login redirect" [--body FILE]    from its worktree, everything committed
mdt handoffs                                                   its handoffs: waiting, taken, sent back (with your note), declined
```

- **A handoff is one commit, fixed when it is made.** MDT fetches the
  branch as it is at that moment and records the commit it got. Later
  commits in the VM don't change what you are looking at; handing off the
  same branch again replaces it with the new commit, and says so.
- **One handoff per worktree,** so each is one session's work. `mdt
  handoff` hands off the branch of the worktree it runs in, and refuses
  in `/work/<name>` itself. Several can wait at once, one per worktree.
- **Uncommitted work isn't handed off:** `mdt handoff` refuses a worktree
  with changes and lists them, so a checkpoint is something the agent
  meant.
- **Where it sits on your machine:** as `vm/<branch>`, kept the way git
  keeps a remote's branches (`refs/remotes/vm/…`). Git won't commit on it
  (checking it out detaches), `git push` leaves it behind, and tools list
  it apart from your branches. It exists only while the handoff waits, so
  any git tool can read the diff too. Nothing else of the VM's is in your
  repository.
- **It asks nothing of you right away.** A line on the Projects page and
  in the activity log. `mdt handoff` returns at once with its id.

```
mdt_client    your branch: master                                         [Sync]

Handoffs
  #7  Fix the login redirect      claude · fix-login · 3 commits · 5 files +120 −34 · merges cleanly             waiting
  #6  Port forwarding, guest side  codex · port-forward · 9 commits · 12 files +800 −20 · conflicts with master   waiting
  #5  Faster inbox writes          claude · taken yesterday

#7  Fix the login redirect
  The agent says:  "The redirect dropped the return path when … `mix precommit` passes."
  Facts:           built on your master as it is now · 5 files, +120 −34
  Hints:           changes mix.exs, which runs when you build
  The whole diff, against your branch

  [Bring it into my working tree]     [Send back with a note]     [Decline]
```

- **Facts and claims apart,** as on approvals. Facts are worked out by
  MDT: the files, the size, what it is built on, whether it merges with
  your working tree as it is now. The title, the description and the
  commit messages are the agent's claims. Hints mark files that run on
  your machine when you build or commit (`mix.exs`, a `Makefile`,
  `package.json`, `.envrc`, CI and editor task files); they are hints, not
  a review.
- **Bring it** takes the whole handoff, never part of it, into your
  working tree as uncommitted changes, merged with what you have there.
  Your branch, your index and anything you staged stay as they were, and
  no commit is made. You look, keep or drop what you like with your usual
  tools, and commit in your own time, under your name.
- **Undo** puts your working tree back: MDT keeps the snapshot it took
  before bringing anything.
- **When it doesn't merge** with what you have, nothing is written. You
  send it back, the agent merges your branch in the VM, resolves there
  and hands off again. You can also bring it anyway, with conflict
  markers.
- **A file of yours that git ignores is never written over.** Where a
  handoff adds a file and you already have one there (a `.env`, say), it
  is in the way and nothing is written.
- **Send back with a note:** the note is what the agent reads in
  `mdt handoffs`. Declining ends it. Either way `vm/<branch>` goes away.
- **What MDT keeps in your repository** besides `vm/<branch>` are refs no
  tool lists, under `refs/mdt/`: the handoff's commit, so a bring can be
  undone after `vm/<branch>` is gone, and the snapshot taken before a
  bring. They go when the handoff is sent back or declined, when the
  project is removed, or when the handoff falls out of the last 50.
- **How a bring works:** a snapshot of your working tree, then
  `git merge-tree --write-tree SNAPSHOT COMMIT`, which computes the merge
  without touching anything, then git itself writes the changed paths from
  the result into the working tree only
  (`git restore --source=TREE --worktree`). Needs git 2.38 or newer.
- **Afterwards the agent catches up by merging,** not rebasing:
  `mdt sync`, then `git merge host/master` in its worktree. Lines you kept
  as they were merge silently, and `git diff host/master` then shows what
  you dropped or changed. Its branch's history is never yours, so its
  shape doesn't matter.
- **Pushing to GitHub** from the VM through a token grant still works,
  for a real pull request.

Copying files instead (rsync, or a two-way sync tool) was considered and
not chosen. It writes what the VM wrote straight into your working tree,
which is what dropping the share was for. Two versions of a file have no
common base to merge from. And it fights git: one branch's files copied
onto another's checkout show up as changes.

Checked on 2026-11-13 with a throwaway VM (msb 0.7.14, Alpine, git 2.54)
and a clone of this repository. The transport and the bring were tried;
the handoff's record, its commands and its screen are design.

| Check                                                                   | Result                                                                                                              |
| ----------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| Plain `msb exec`                                                        | Holds output until the command ends, so git's protocol stalls. `--stream` sends it at once, unchanged (256 MiB, same SHA-256) |
| The pipe's speed                                                        | 60 MiB/s into the VM, 138 MiB/s out; 0.03 s for an empty call                                                        |
| The whole repository into the VM (6 MiB)                                | 0.25 s; 0.03 s when nothing is new                                                                                   |
| A VM branch out                                                         | 0.05 s; 0.03 s when nothing is new                                                                                   |
| Snapshot of uncommitted work                                            | `git status` identical before and after; the edit and the new file were in it, `_build` was not                      |
| Both sides edit the same line                                           | Both transfers pass and no tree changes. The conflict shows only when the agent brings your branch into its own, in the VM, and is resolved there |
| Hooks, `core.fsmonitor`, `core.pager`, `core.sshCommand` planted in the VM's repository | None ran on the host (6 hooks ran in the VM); the host's `.git/config` and hooks unchanged          |
| A tree holding `.git/config`, offered by the VM                         | Refused: "fsck error in packed object"                                                                               |
| `/work/<name>` following                                                | Clean and behind: updated. Uncommitted edit, or commits of its own: left alone. `host/master` updated in all three   |

Bringing a branch's changes in, checked the same day in a plain
repository (git 2.56; `take_probe.sh`). The VM's branch edited three
files, added one and deleted one; you had one staged change and two
unstaged edits. The test wrote four of the five files; a bring writes all:

| Check                                             | Result                                                                  |
| ------------------------------------------------- | ----------------------------------------------------------------------- |
| HEAD, the index, your branches, before and after  | Identical; no commit on `master`                                        |
| Your staged change                                | Still staged                                                            |
| A file both edited, on different lines            | Both edits there                                                        |
| A file both edited, on the same line              | Reported as a conflict before anything was written                      |
| The new file, the deleted file                    | Untracked; removed                                                      |
| Undo                                              | `git status` back to what it was                                        |

Scripts and output: `test/review/vm_sync` on the `sandbox-review` branch.

### What MDT hands to the VM

Today MDT writes its instruction block into `~/.claude/CLAUDE.md` and
`~/.codex/AGENTS.md` in Home, and copies `memo` into the VM's OptMem
folder, from the host. Both follow a symlink the VM plants, so a host file
gets rewritten at the next start. From now on:

- **MDT writes only `/mnt/mdt`,** which the VM can't change. `memo` goes
  to `/mnt/mdt/bin`.
- **The VM copies for itself.** After each boot MDT runs one script from
  `/mnt/mdt/bin`, inside the VM (`msb exec`), that puts the block between
  its markers in the agents' files. A symlink there now points inside the
  VM.
- With Home on a disk, the host has no path to it anyway.

### Host commands become a grant

A fourth type, beside `token`, `network` and `file`:

| Type      | What the VM gets                                      | Approval                          | Turning it off                                             |
| --------- | ----------------------------------------------------- | --------------------------------- | ---------------------------------------------------------- |
| `command` | Nothing. It may ask MDT to run a command on your machine | Per run, of the exact text. No allowance | New asks are refused. A command already running goes on until it ends or you stop it |

```elixir
%Grant{
  kind: :command,
  purpose: "Deploy the docs site to staging",
  script: "./deploy.sh staging",          # fixed; nil = agents write the text
  dir: "/home/me/projects/site"           # where a fixed script runs
}
```

- **Two forms:**
    - *Fixed:* you write the script and its folder. Agents run it by the
      grant's name and send no text: `mdt run GRANT --reason "…"`.
    - *Any command:* agents send the text, as today:
      `mdt run GRANT --reason "…" -- COMMAND`. Labeled as the widest grant
      there is, the way file grants are labeled a last resort.
- **Off by default, by not existing.** With no command grant, `mdt run`
  is refused and says how to ask (`mdt request --need "…"`), which you
  answer by setting one up, or not.
- **It behaves like any grant:** on for a time or until turned off, with
  your words for what it is for, listed by `mdt grants`, asked for with
  `mdt request`, with its own activity.
- **Every run still waits for you,** fixed or not, with the card as it is
  today; the approval now names its grant. No allowance covers a command
  (the 11-12 decision stands).
- **Where it runs:** a fixed script in the grant's folder. Any command in
  `--dir` when that is inside a share, otherwise in your home folder: an
  agent's own folder is on the Work disk now, which the host doesn't have.
  The folder is resolved again when the command starts (`cd -P`, then
  compared), so swapping it for a symlink after the ask changes nothing.
- `mdt host` needs no grant: it only reads.

### The image stays local

Unchanged: the recipe ships with MDT (`priv/sandbox`), and podman builds
it on your machine. Nothing is pulled from a registry of MDT's. So podman
is a package dependency, and the Checks screen says so when it is missing.

### Developing MDT itself

- **Your MDT** is the installed package, from the last tag or from
  `./scripts/build-linux.sh`. It holds your real vault and the VM agents
  work in, and loads no code from a folder a VM can write. Today the dev
  server runs from the checkout the VM writes, so an agent's edit to
  `lib/`, or to the `msb` in `_build`, runs on your machine.
- **Agents in the VM** work on MDT as a [project](#projects): a worktree
  from `host/master`, `mix precommit`, then `mdt handoff`. You review the
  [handoff](#handoffs), bring it in and commit it yourself. The "work in
  a worktree" section of `AGENTS.md` is rewritten for it once projects
  exist.
- **Trying a change:** a dev MDT with a data folder of its own
  (`MDT_RUN_DIR`), so its own identities, microsandbox home and VM. On the
  host when the change touches the VM; inside the VM for anything else.
- **Packages** are built by CI from the tag, as now, after the tests on a
  real VM pass on Fedora and Ubuntu.
- **Cost:** a merged change reaches your own MDT only when you install a
  new build (about 8 minutes for an rpm here).

### Order of work

| Step | What                                                                                                                                              | Done when                                                                                   |
| ---- | ------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------- |
| 1    | Close the gaps the 11-13 review proved: approvals joined too loosely, expiry never checked, host writes that follow the VM's symlinks, a command's folder swapped after the ask, GraphQL and Host spoofing, `TRACE`, values in a crash log, the 10-second CONNECT wait, the inbox rewrite, unbounded certificates. With them the one-line speedups (socket buffers, `nodelay`, roots loaded once, chunked bodies, connecting while peeking). | The 16 tests in `test/review/sandbox_intent_test.exs` pass and move into the suite; the three benchmarks are rerun. |
| 2    | The VM layer: the bubble and relay, the proxy and DNS on sockets, per-identity microsandbox home, the three disks, clean stops, the launcher's refusals, the Checks screen. | A test on a real VM passes every row of the table above, plus disks kept across a recreate. Throughput through the relay is measured. |
| 3    | Projects: adding one, sync to the VM, `mdt sync`, `mdt handoff`, and the handoff screen (review, bring, undo, send back).                         | On a real VM: a handoff is listed with its diff, brought in uncommitted with your branch and index unchanged, undone, and sent back with a note the agent reads; a planted hook runs nowhere on the host. |
| 4    | The `command` grant.                                                                                                                              | A new identity can't run anything on the host; fixed and any-command runs pass on a real VM. |
| 5    | A pure `Policy.decide(snapshot, use, now)`, `Server` split into Grants, Approvals, VM and HostRuns, and intercepted hosts served by Bandit and Finch instead of the hand-written parser (after a one-day spike: websocket upgrades, holding a body). | Policy has property tests; a corpus of malformed and ambiguous requests is refused.          |
| 6    | Release engineering: package dependencies (`bubblewrap`, `podman`, `e2fsprogs`), the real-VM suite run from the installed package on Fedora and Ubuntu, signed checksums, a page on what MDT protects and what it doesn't, how to report a security problem. | A fresh Fedora and a fresh Ubuntu go from install to a handoff brought in and committed by you.     |
| 7    | You use the release candidate every day, with agents on the new workflow.                                                                         | A week without a blocker; then the tag.                                                     |

Step 1 was built on 2026-11-13, uncommitted on the `sandbox-review`
branch. The 16 tests are `test/mdt_client/sandbox/guarantees_test.exs`,
with more in `egress_test.exs` and `graphql_test.exs`. Two things differ
from the list above:

- **Host writes into Home and the VM's OptMem** no longer follow links.
  Moving them out of there altogether comes with step 2, as
  [What MDT hands to the VM](#what-mdt-hands-to-the-vm) says.
- **The system roots** go to the proxy's own connections as a file
  (`MDTClient.Sandbox.Roots`), which `ssl` reads once, instead of a list
  it takes in again per connection.

Measured again on loopback, same benchmarks as the review:

| Path                                      | Before       | After        |
| ----------------------------------------- | ------------ | ------------ |
| Tunnel, 1 GiB                             | 1.1 GiB/s, about 300 ms of CPU per GiB | 3.6 GiB/s, 16 ms |
| One intercepted GET                       | 50.6 ms      | 6.8 ms       |
| 64 intercepted requests at once           | 243 per second | 519 per second |
| A 27-byte chunked body                    | 2,007 ms     | 4.8 ms       |
| A server that speaks first, to first byte | 1.5 s        | 0.11 s       |

Step 2 was built the same day, uncommitted on the same branch: the relay
(`native/mdt_relay`, `scripts/build-relay.sh`), `Bubble`, `Sockets`, `Dns`,
`Disks`, the per-identity `Msb`, the boot script (`priv/sandbox/mdt-boot`),
shares read-only by default, and the package dependencies. `mix test
--only vm` boots a real VM (Alpine, msb 0.7.14) twice, in 34 seconds here:

| Check, on a real VM with MDT's own proxy, DNS forwarder and channel   | Result |
| ---------------------------------------------------------------------- | ------ |
| The VM's process: seven namespaces of its own, no `/home`, `/etc` or `/run` of yours, `lo` only, no capability held or regainable | Pass |
| `/root`, `/cache`, `/work` are ext4 disks; `/mnt/mdt` and the VM's memory are folders; a share is read-only | Pass |
| HTTP out is in MDT's activity log, and so is the name it looked up     | Pass   |
| A name asked of 8.8.8.8 gets no answer and is in no log                | Pass   |
| `mdt grants` over vsock, with bash and socat fetched through MDT       | Pass   |
| The boot script puts the instructions in the agents' files, and `memo` with an empty memory in the VM's own folder | Pass |
| Stop, start, recreate: the three disks keep their files, the root disk starts over | Pass |
| `msb start` and `msb exec` from outside the bubble boot nothing        | Pass   |
| MDT locked: the VM runs on, without internet                            | Pass   |
| The sandbox itself creates, stops, starts and recreates it (Home emptied, a copy kept, Work untouched), and stops it when you lock | Pass |
| The launcher goes into the VM while it runs, and refuses after         | Pass   |

With the Python stand-ins of the earlier check on MDT's side: 1 GiB from
the host side into the VM, through msb, the relay and the socket, at 610
MiB/s; create and boot in 0.5 s, start in 0.4 s.

Step 4, the `command` grant, was built the same day as well: the fourth
grant type, with a script of yours or for any command; `mdt run GRANT`; no
allowance and no "allow every use" for one; the approval names its grant.
`mdt` no longer reads a script from a stdin that has nothing in it, so a
run of your own script never waits on one. Checked in a real VM: with no
command grant `mdt run` is refused, and a grant with a script of yours
waits for approval with that script, in its folder.

Step 3 was built the same day too: `Guest`, `HostGit`, `Project`, `Sync`,
`Handoff`, `Projects`, the `mdt sync`, `mdt handoff` and `mdt handoffs`
commands, and the Projects page. Its tests use a folder of this machine in
the VM's place (`projects_test.exs`, `projects_flow_test.exs`,
`sandbox_projects_live_test.exs`); `mix test --only vm` does the same
through a real VM, with the real `mdt` command in it:

| Check, through msb's pipe into a VM in the bubble                      | Result |
| ---------------------------------------------------------------------- | ------ |
| A sync makes the copy on your branch; a second one finds it current    | Pass   |
| A handoff from a worktree arrives, with its facts                      | Pass   |
| It comes into your working tree uncommitted, HEAD unmoved; undo puts the tree back | Pass |
| A hook and `core.fsmonitor` planted in the VM's repository run there, never here | Pass |
| `mdt sync`, `mdt handoff` and `mdt handoffs`, run in the VM            | Pass   |

<a id="step-5"></a>

Step 5 was built the same day too, with one part of it decided against:

- **The decision is one pure function.**
  `Policy.decide(snapshot, use, now)` answers pass, allow, ask or refuse
  for a connection, a request or a command, and the server acts on the
  answer. `policy_test.exs` checks its rules for every combination of a
  small world: 40,320 requests, 16,128 connections and 1,620 asks to run a
  command.
- **Text the VM chooses** turned up while those tests were written: raw
  bytes and invisible characters reached approval cards. See
  [Text the VM chooses](#text-the-vm-chooses), and the limits on what MDT
  reads from git there.
- **The server is the process and six modules**, from 3,000 lines in one:
  `Server` (1,070 lines, every message), `State`, `Grants`, `Approvals`,
  `Values`, `HostRuns` and `Machine`. One process and one state as before:
  the functions were moved by a script, not rewritten, and
  `Settings.cast/2` took the settings form's checks.
- **Bandit and Finch for intercepted hosts were tried and not taken.**

| Question                        | What the spike found (`test/review/http_spike/`)                                                                                   |
| ------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| The corpus of 65 requests       | Of the 52 MDT's reader refuses, Bandit refuses 39. It takes 7 by reading leniently (a list as `Content-Length`, bare line feeds, a full address as the target) and 6 a Plug would have to refuse itself (`TRACE`, `CONNECT`, the `Host` rules). Finch rewrites what goes out, so none is a way through |
| A request held for your answer  | Works: held 70 s, then sent on                                                                                                     |
| An upgrade (WebSocket)          | Reaches the Plug as an ordinary request. Passing it on takes a WebSocket client, which MDT doesn't have; today it is bytes after the head |
| A header value outside ASCII    | Mint refuses to send it (`502`); MDT's reader passes it on, as HTTP allows                                                         |
| Giving Bandit the connection    | No supported way to hand it a connection MDT accepted and decrypted: a second listener on loopback with a table of which VM connection is which, or Bandit's private modules |
| Time                            | 0.11 ms a request with connections kept on both sides, 1.5 ms with a new TLS connection each (loopback). To api.github.com from here a new connection costs about 27 ms before the request goes |

  The gain would be about 30 ms a request, and every request on a kept
  connection judged on its own. The cost is the upgrade pipe, a private
  API or a second listener, and a rewrite of the path that was just
  hardened and measured. What carries over is the corpus: MDT's reader
  passes it, after three fixes it found (only spaces and tabs are trimmed
  from a value; a head over 64 KiB is refused even when it arrives at
  once; bare line feeds get an answer instead of a wait).

`mix precommit` passes with 875 tests, and `mix test --only vm` with its
two on a real VM.

<a id="step-6"></a>

Step 6 was started the same day with what this machine could check: Ubuntu
24.04 and 26.04 under qemu, with KVM passed through so a VM runs inside
(`test/review/ubuntu_check/`). The same check as step 2's, as an ordinary
user, with MDT's runtime as it is built here:

| Ubuntu, as an ordinary user                                   | 24.04 (bwrap 0.9.0)                          | 26.04 (bwrap 0.11.1)                              |
| ------------------------------------------------------------- | -------------------------------------------- | ------------------------------------------------- |
| The bubble with the system's bwrap, as it comes               | Fails: `loopback: Failed RTM_NEWADDR`        | Fails: the relay may not add its route            |
| An AppArmor profile on the program that starts bwrap          | Works                                        | Fails: bwrap's own profile takes over             |
| A copy of bwrap with a profile of its own, left unconfined    | Works                                        | Works                                             |
| The same copy under the profile the deb installs              | Works: 28 of 28 rows                         | Works: 27 of 27 rows (before the last was added)  |
| Inside that copy: `CAP_NET_ADMIN`; a raw socket (`CAP_NET_RAW`) | Allowed; refused                           | Allowed; refused                                  |
| 128 MiB into the VM through the relay, a VM inside a VM       | 162 MiB/s                                    | 158 MiB/s                                         |

Two things kept the sandbox from starting on Ubuntu, and both are closed:

- **AppArmor.** Since 24.04 a program holds capabilities in a user
  namespace only under a profile that allows it, and 26.04's profile for
  `/usr/bin/bwrap` lets bwrap make the namespaces but gives what runs in
  them no capability. The relay needs one, once, for the route into
  loopback. The deb's install script (`scripts/deb/postinst.sh`) copies the
  system's bwrap to `/usr/lib/mdt/bwrap` and loads a profile for that
  path, modelled on Ubuntu's own: what runs inside may hold
  `CAP_NET_ADMIN` and `CAP_SETPCAP` and no other. `Bubble.bwrap/0` uses
  that copy when it is there. Any program of yours can run the copy, so on
  a machine with MDT installed a program can get those two capabilities in
  namespaces of its own, which hold no network of the machine's. The copy
  is the system's bwrap of the day MDT was installed; installing MDT again
  refreshes it.
- **The umask.** Ubuntu's is 002, so MDT's folders were writable by your
  group, and msb refuses a store under such a folder. `Msb.ensure_home!/1`
  now makes the store and the folders above it, up to MDT's own, `0700`.

`Bubble.available/0` now makes a bubble for real and runs the relay's
first two steps in it (`mdt-relay --check`), so a system that refuses is
told apart before a VM is offered, and the Setup page says what to run.

Still to do in step 6: the deb and the rpm built with these scripts and
installed on fresh machines, signed checksums, the page on what MDT
protects, and how to report a security problem.

#### Moving a VM from before the disks

Not built, and not tried as written: the one VM that exists is yours. The
new VM starts with empty disks, and its image must be built once more in
MDT, since each identity now has its own microsandbox home. What the old
VM kept is still where it was, in the identity's sandbox folder
(`~/.mdt_client/identities/<id>/sandbox/home` and `…/cache`).

1. Build the image and start the VM in MDT.
2. Home, through msb's pipe, with the launcher shown on the Setup page:

       tar -C ~/.mdt_client/identities/<id>/sandbox/home -cf - . |
         <launcher> exec --stream <vm> -- tar -C /root -xpf -

3. Cache is not worth moving: tools and packages download again. Projects
   come in by sync.
4. When the new VM has what you need, the old folders (`home`, `cache`,
   `snapshots`) and the old shared microsandbox home
   (`~/.mdt_client/microsandbox`, several GB) can be deleted.

### Not checked yet

- **The deb itself.** Ubuntu was checked with the package's install
  script run by hand in an Ubuntu VM ([step 6](#step-6)); the deb that
  runs it, and MDT started from that deb, were not built here.
- **Zed** through `msb ssh serve` with the VM in the bubble. `msb exec`
  from outside works, and the launcher was tried with `exec` only.
- **A seccomp filter** for msb in the bubble: `bwrap` can load one; the
  VM's process still has none.
- **The pinned msb.** Every check ran the 0.7.14 runtime, not
  `0.7.15+6626e7cb2`.
- **MDT's own image.** The real-VM tests use Alpine; the 4.5 GB image and
  a VM made through the pages were not tried.
- **Not built yet for handoffs:** a desktop notification when one
  arrives, a folder picker for adding a project, and the handoffs in
  MDT's Git tool.
- **Submodules and LFS files** in a project.
- **A large repository.** At the pipe's speed, 1 GiB would take about
  17 s to go in; not tried.
- **`msb cp`** for folders that aren't repositories.
- **VPN,** still open from 2026-11-11.

### Known and left open

Found while building step 5, none of them a way to a real value:

- **A passed-through connection is logged under the name the VM gave**
  (the TLS name), which MDT doesn't check against the address. The VM can
  make a connection to any public address read as `github.com` in the log.
  MDT sees every lookup now, so it could say when a name and an address
  never met.
- **The activity log is the last 1,000 events, in memory.** A VM can push
  older ones out with noise, and a restart empties it. A log kept on disk,
  sealed, would hold.
- **What the VM sends behind a request MDT read** goes to the host unread
  and unlogged. It carries a placeholder at most
  ([Each intercepted request](#each-intercepted-request)).
- **DNS carries data out.** Every lookup is logged, none is judged.
- **Letters that look alike.** A script mixing alphabets gets a hint;
  everywhere else such text is shown as it is.
- **A host name in a network grant is resolved inside the sandbox's
  process**, for each connection to a private or reserved address. A slow
  resolver makes everything wait.

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
| Notifications        | `…DesktopNotice`, `Desktop.Notifications`        | One per approval waiting for you, closed once it is decided; a click brings MDT forward on it. A small D-Bus client of MDT's own (`MDTClient.DBus`). See [Desktop notifications](#desktop-notifications). |

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
VM ──all TCP──▶ msb ──HTTP CONNECT ip:port──▶ relay ──proxy.sock──▶ MDT egress proxy
                                               │
                                               ├─ loopback, link-local, host's own addresses → deny
                                               ├─ private ranges (VPN, LAN) → deny unless a network grant is on
                                               ├─ TLS to a host with an HTTP grant → intercept
                                               │     read request → placeholder? → allowance or approve → swap → forward
                                               └─ anything else → blind byte tunnel (log host, bytes, duration)

VM ──DNS──▶ msb ──▶ relay ──dns.sock──▶ MDT DNS forwarder ──▶ this machine's resolver (every name logged)

VM ──vsock:5000──▶ $XDG_RUNTIME_DIR/mdt/<id>/channel.sock ──▶ agent channel (`mdt grants`, `mdt request`, `mdt run`, `mdt host`, `mdt wait`)
                                                                   │
                                                                   └─ `mdt run`, once you approve it ──▶ bash -lc on the host, as you

/mnt/mdt (read-only, from host): CA certificate, placeholder env file, the `mdt` command, git credential helper, file grants, host.md
/root/.optmem (read-write, from host): the VM's own OptMem
/root, /cache, /work: the VM's own disks (ext4 images on the host, which nothing there opens)

msb and the relay run in a bubble (bwrap): no home folder of yours, no network but loopback
```

The VM is created with `--proxy http://127.0.0.1:3128` and
`--dns-nameserver 127.0.0.1:5353`: ports that exist only in the bubble
microsandbox runs in, where MDT's relay joins them to MDT's sockets (see
[The VM runs in a bubble](#the-bubble)). All of the VM's TCP goes through
MDT, and it cannot opt out the way it could ignore `HTTPS_PROXY`; the bubble
has no network of its own to go around MDT with. When MDT is not running,
the VM has no internet and resolves no name. With an HTTP CONNECT proxy,
microsandbox blocks UDP other than DNS, so HTTP/3 cannot go around the
proxy.

<a id="grants-and-approvals"></a>

## Grant kinds

A grant is one piece of access you can turn on and off. It has one of four
generic types, none tied to a provider, and your own words for what it is
for, which agents read to find the grant they need.

| Type      | What the VM gets                                                                   | Approval       | Turning it off                                                                |
| --------- | ---------------------------------------------------------------------------------- | -------------- | ----------------------------------------------------------------------------- |
| `token`   | A placeholder, in variables, in a token file, and as git's password if you choose. | Per request    | Takes effect on the next request. Complete, since the VM never had the value. |
| `network` | Reachability to listed hosts, address ranges and ports                             | Per connection | New connections refused, open ones closed                                     |
| `file`    | The real value, as a file in `/mnt/mdt/files`                                      | None possible  | File deleted. **Copies survive.** Only expiry at the provider ends it.        |
| `command` | Nothing. It may ask MDT to run a command on your machine                           | Per run, no allowance | New asks are refused. A command already running goes on until it ends or you stop it. |

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
  kind: :token,                      # :token | :network | :file | :command
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

  # :command
  script: "./deploy.sh staging",     # yours; nil = agents write the text
  dir: "/home/me/projects/site",     # where a script of yours runs

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
   A CONNECT is answered within 3 seconds, because microsandbox gives up on
   one after 10. A connection still waiting for your approval then gets its
   200 and the open tunnel waits instead; a "no" closes it.
2. **Private ranges** (RFC 1918, ULA, `100.64.0.0/10`): allowed only when an
   `on` network grant matches the IP and port. Grant hostnames are resolved
   with the host's DNS, which knows VPN names. The connection waits for
   approval unless an allowance covers its address and port.
3. **Peek** at the first bytes. For a TLS ClientHello, read the hostname
   (SNI). A client that speaks first does so at once. After 100 ms of
   silence MDT also connects to the destination and takes the first bytes
   from whichever side speaks, so a server that greets first (SSH, SMTP,
   MySQL) is heard in 0.1 s instead of 1.5.
4. If the hostname belongs to **any registered token grant, on or off**,
   intercept. Off grants are intercepted too, so the agent gets a clear answer
   instead of an auth failure from the provider.
5. Otherwise, **tunnel** bytes both ways without reading them.

### Each intercepted request

1. Finish the TLS handshake with a certificate MDT's CA makes for that
   hostname. Offer HTTP/1.1 only.
2. Read the request head, strictly. MDT judges a request by what it read,
   and the host must act on the same thing, so a request two parsers could
   read two ways is refused (`400`, `mdt_bad_request`):
    - the target must be a path, not a full URL;
    - exactly one `Host`, the TLS hostname (`421` otherwise): a mismatch
      would let a request say "github" to MDT while going somewhere else;
    - one way of saying how long the body is: one numeric `Content-Length`
      or `Transfer-Encoding: chunked`, never both;
    - the target is visible ASCII, as HTTP says: anything else arrives
      percent-encoded or not at all;
    - every header line is `name: value`: no folded lines, no space before
      the colon, a name of token characters only;
    - a value is visible bytes, spaces and tabs, and only the spaces and
      tabs around it are dropped: no other control character, no bare CR
      or LF;
    - lines end in CR LF, and the head is at most 64 KiB (`431`);
    - `TRACE` and `CONNECT` are refused (`405`): a host answers `TRACE` with
      the request it got, real value included.

   The TLS name itself must be a host name (letters, digits, dots, dashes,
   underscores). Any other bytes name nothing: the connection is passed
   through unread, under its address.
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

One request per connection: MDT sends the head it wrote itself, with
`Connection: close`, so each request is judged on its own and turning a
grant off affects the very next one. The real value is written once, into
that head. Whatever the VM sends after it (the body, and anything behind
the body) is passed on as bytes MDT never wrote a value into, so a second
request hidden there reaches the host with its placeholder, which opens
nothing.

A corpus of 65 requests, malformed or written to be read two ways
(`test/support/sandbox_corpus.ex`), goes through the proxy in the suite,
each with the placeholder of a grant that lets every use through. Each is
refused whole, or reaches the host as one request with the head MDT wrote.

`Upgrade` (websockets) on an intercepted host: the handshake goes through the
steps above, then bytes are tunnelled.

### Describing requests

An approval shows facts MDT worked out, not what the agent says.

| Describer      | Facts                                                                                               |
| -------------- | --------------------------------------------------------------------------------------------------- |
| GitHub git     | `push owner/repo: refs/heads/main abc123→def456` (read from the receive-pack commands); fetch/clone |
| GitHub GraphQL | the type and the fields of the operation a server would run (`mutation`, `createPullRequest`)       |
| GitHub REST    | method, resource path (`POST /repos/o/r/pulls`)                                                     |
| Hex            | publish/retire/owner change, package and version                                                    |
| Generic        | method, host, path, query, start of body                                                            |

Text the agent wrote (commit messages, PR bodies, a stated reason) is shown in
a separate, labeled area. It is a claim, never a fact.

A GraphQL document is read with a tokenizer (`MDTClient.Sandbox.GraphQL`),
not matched as text: the operation is the one `operationName` selects, a
comment or a string can't pose as one, an alias is read through to its
field, and fields behind fragments count. An operation's name is its
author's, so "allow similar" goes by the whole document: the same document
with other variables is similar, another document with the same name is
not.

<a id="text-the-vm-chooses"></a>

### Text the VM chooses

Most of what an approval shows was picked by the agent: paths, header
values, ref and file names, reasons, commit messages, scripts. Before
2026-11-13 it went to the pages as it came. A path with one raw byte in it
reached an approval's title, and from there the JSON every page is sent
as, which takes UTF-8 only; a right-to-left override (U+202E) in a title
or a script made a line read as something else.

`MDTClient.Sandbox.Shown` makes such text show all it holds: what isn't
UTF-8 becomes `�`, and a control or format character is written out, as
`\u{202E}`. Tabs and new lines stay. It is applied where the text enters
MDT, so the pages don't have to think about it:

| Way in                         | What happens there                                                              |
| ------------------------------ | ------------------------------------------------------------------------------- |
| A request MDT reads            | The target must be visible ASCII; titles, facts and claims are made to show all |
| The TLS name of a connection   | A host name, or the connection is passed through under its address              |
| A DNS question                 | Visible ASCII labels, or it isn't answered                                      |
| An ask on the agent channel    | Text, whole numbers and yes or no; anything else in it counts as nothing        |
| A script for your machine      | Never changed: one that hides anything is refused, and the agent is told what   |
| A folder for that script       | One whose real name hides anything isn't used: the command runs in your home    |
| A handoff                      | Its title, body, commit messages, file names and diff                           |
| What git says when it fails    | Shown text; what it prints on success stays git's bytes, for MDT to read        |
| A held request, read or copied | Headers, body, the HTTP text and the curl command                               |

A request's pattern, which an allowance is matched on, is compared and so
never merged: two that differ stay different once made safe to show.

A script that mixes alphabets in one word (`gіthub.com` with a Cyrillic
`і`) gets a hint on its card. That is a hint, not a check.

Sizes are the VM's to choose too. MDT reads at most 32 MiB of what one git
command prints and fails past that; of a handoff's diff it reads the first
512 KiB and says so; and a handoff may bring at most 1 GiB of new data
into your repository (the fetch runs under a file size limit, and what a
stopped fetch left is removed).

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

### Desktop notifications

Agents ask while you work in another window, so every approval waiting
for you is also a desktop notification: an agent asking for a grant or to
run a command, a held request, a connection, and a command whose output
waits for you. It says who asked, for what, the agent's reason in quotes,
and when it gives up. It closes as soon as the approval is decided or
gives up, from any window, and when the vault locks. A command coming
back with its output gets a new one. One you dismiss isn't shown again.

Nothing is decided from a notification. Clicking it (or its Review button)
brings MDT's window forward on the Approvals page, with that approval
ringed and scrolled into view, where the facts sit beside the agent's
claims. A notification can show neither the full script nor the request.

The switch is on the Settings page (per identity, on by default), with a
test button and what the desktop answered. GNOME lists the notifications
under MDT in its own settings, where banners and sounds can be turned off.

How it works on GNOME (checked against GNOME Shell 50.6's
`notificationDaemon.js`, on Fedora 44, Wayland):

- MDT speaks to `org.freedesktop.Notifications` on the session bus over
  one connection it keeps open (`MDTClient.DBus.Connection`, a small D-Bus
  client: SASL `EXTERNAL`, the wire format for the types it needs). GNOME
  sends `ActionInvoked`, `ActivationToken` and `NotificationClosed` only
  to the connection that showed the notification, and destroys an app's
  notifications when that connection goes away. So `notify-send` and
  `gdbus call` can't do it: with MDT's desktop entry they vanish at once.
- Notifications name `desktop-entry` `MDT` (`MDT.desktop`, installed by the
  packages), so GNOME shows MDT's name and icon and applies its per-app
  switch.
- On Wayland a window may take focus only with an activation token, which
  GNOME sends with the click. MDT passes it to the page, the page to the
  shell's `present_window` command, and the shell to GTK
  (`gdk_wayland_display_set_startup_notification_id`, then `present`).
  On X11 the token is a startup id. Without the shell (a browser on
  `mix phx.server`) the page still opens the approval.
- With no session bus or no notification service, MDT keeps track of what
  it would show and tries again every 30 seconds. Signals are taken only
  from the service that showed the notification.

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

Since 2026-11-13 these are disk images, with a third for work: see
[Storage: the VM's own disks](#storage-the-vms-own-disks). What follows
still holds for what each is for and what recreating asks; a snapshot is
now a copy of the Home disk's file.

Two disks inside the identity's sandbox folder:

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

After each boot, the VM puts MDT's block at the top of `~/.claude/CLAUDE.md`
and `~/.codex/AGENTS.md` in its Home, between markers: MDT runs
`/mnt/mdt/bin/mdt-boot` in it (`msb exec`), which copies the block from
`/mnt/mdt/agents-block.md`. The rest of each file is left alone. MDT itself
writes nothing into Home. An image without Bash can't run the script; the
VM still runs, and MDT logs it. The same text is at `/mnt/mdt/AGENTS.md`.
It says:

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
`$XDG_RUNTIME_DIR/mdt/<id>/channel.sock` (Unix socket paths are short, so
not the identity's folder; `MDTClient.Sandbox.Sockets`), which
`msb create --vsock /mdt/sockets/channel.sock:5000`, run in the bubble,
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
mdt run GRANT --reason "…" [-- COMMAND]      see Host commands
mdt host                                     see Host commands
mdt sync                                     see Projects
mdt handoff --title "…" [--body FILE]        see Projects
mdt handoffs                                 see Projects
mdt vm                                       which VM this is, and whether MDT runs it
```

- `vm` tells an old VM from the one MDT runs. MDT gives each VM it creates
  an id and records when, and from which image (`VM`'s `record`; a VM made
  before records gets one at its next start). The boot script writes the
  same into the VM, at `/etc/mdt-vm`, and `mdt vm` sends that id for MDT to
  compare: 0 this is the VM MDT runs, 3 it isn't (or MDT's is stopped), 1
  there is no record to compare, 4 MDT doesn't answer. Every interactive
  login shell (Zed's terminals) prints the answer in a line, dim, or red
  when it isn't 0; agents' shells, which aren't interactive, print nothing.
  The Overview shows the same id. Added 2026-11-13, after a Zed window
  stayed connected to a VM MDT no longer ran and its agents saw only
  "connection refused".
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
mdt run GRANT --reason "…" [--dir DIR] [--timeout 120] [--wait 60] [-- COMMAND [ARG…]]
mdt run GRANT --reason "…" [options] <<'EOF'   the script from stdin
…
EOF
mdt wait RUN_ID [--wait 60]
```

- **Through a command grant** (since 2026-11-13, see
  [Host commands become a grant](#host-commands-become-a-grant)). None
  exists until you add one, so on a new install `mdt run` is refused and
  says how to ask for one. A grant with a script of yours runs that text,
  in its folder, and takes none from the agent; any other takes the text
  below. The one word before `--` is the grant, so a typo is never run as
  a command.

- **The script travels in the ask.** Arguments after `--` are quoted for
  the shell and joined; a single argument is taken as a shell line as it
  is. With no arguments, the script is read from stdin. At most 16 KiB.
  What you read on the card is what runs. A script in a file the VM can
  write could change between your click and the run, so
  `mdt run -- ./deploy.sh` is flagged. A script holding anything that
  doesn't show (a control character, a zero-width one, a right-to-left
  override, bytes that aren't UTF-8) is refused before it waits for you,
  and the agent is told which ([Text the VM chooses](#text-the-vm-chooses)).
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
- The directory on the card is a real path, and the command starts there
  after `cd -P` and a check that the path still leads there. A folder the
  VM can write may have been swapped for a link since you looked: then
  nothing runs, and the agent gets exit 126.
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
login shell's `PATH`, with their versions. Then your own notes about the
machine, from Settings. MDT collects it when it unlocks, and when you ask
from Settings; agents never probe the host to find out.

## VM

- **Checks:** KVM is available, MDT's `msb` and relay are there (see
  [Runtime](#runtime)), `bwrap` may create user namespaces, the tools that
  make disks are installed, the image exists.
- **Image:** see [Image and VM state](#image-and-vm-state). The checks
  showed what TLS needs: the `ca-certificates` package (without it Erlang
  finds no CAs at all), MDT's CA in the system bundle (curl, git, `gh`,
  Python's `ssl`), `HEX_CACERTS_PATH` and `CLOUDSDK_CORE_CUSTOM_CA_CERTS_FILE`.
  Hex gives up after 15 seconds by default, shorter than any approval, hence
  `HEX_HTTP_TIMEOUT`.
- **Created with,** in the bubble, every part named by its path there:
    - `--proxy http://127.0.0.1:3128` and `--dns-nameserver 127.0.0.1:5353`,
      the relay's ports;
    - `--net public,private`, so private ranges reach MDT, which gates them.
      Access to the host stays blocked;
    - `--mount-disk` for Home at `/root`, Cache at `/cache` and Work at
      `/work`;
    - one mount per shared folder, at the path it has on your machine;
    - the read-only `/mnt/mdt`;
    - the OptMem folder;
    - `--vsock` for the agent channel;
    - CPU and memory limits;
    - `--root-disk` and a `quota=` on every read-write folder (see Disk).
- **Disk:** the root disk and folder writes are applied by recreating; the
  sizes of Home, Cache and Work at the next start (bigger only).
    - *Root disk* (64 GiB): what the image and the VM write outside its
      folders, apt packages, `/tmp` and `/var` included. A sparse ext4
      image, so it takes host space only as it fills; it starts empty on
      every recreate. microsandbox's default is 4 GiB.
    - *Folder writes* (64 GiB): how much the VM may add to each read-write
      folder (OptMem, shares) per boot, beyond what was there
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
- **Lifecycle:** MDT starts the bubble with `msb create` or `msb start` in
  it, and stops the VM through the relay (`MDTClient.Sandbox.Bubble`).
  Settings that need recreating are shown as "recreate to apply". The VM
  stops when MDT quits or locks, cleanly: its disks are block devices, and a
  VM cut off loses what it hadn't written out yet.
- **Not started from Zed:** `msb ssh` boots a stopped VM by itself, outside
  the bubble. The launcher refuses it while the VM isn't running, and the
  VM couldn't boot there anyway: its disks are at paths only the bubble has.

### Runtime

MDT brings its own microsandbox and relay. The machine needs `bwrap`
(bubblewrap), podman and e2fsprogs, which the packages depend on.

- **What ships:** `msb` built from MDT's fork,
  [oliveigah/microsandbox](https://github.com/oliveigah/microsandbox) at
  commit `6626e7cb2`: v0.7.15 plus the
  [live-sharing fix](../priv/sandbox/microsandbox-live-sharing.md), and
  v0.7.15's `libkrunfw.so.5.6.1` (the guest kernel). The fix is why it
  isn't the stock release: without it, git in the VM can see an empty index
  after the host replaces it (see the blocker below). It goes back to stock
  once upstream ships the fix.
- **Built by** `scripts/build-microsandbox.sh` into `priv/microsandbox`
  (`bin/msb`, `lib/libkrunfw.so.5.6.1`), so the release carries it and
  `msb` finds its kernel beside `bin/`. Everything is pinned there: the
  fork commit (fetched by hash, refused with local changes), and the SHA-256
  of the guest agent (embedded in `msb`) and of `libkrunfw`. `VERSION`
  (`0.7.15+6626e7cb2`) names the build: a `priv/microsandbox/VERSION` that
  differs means the pin moved and the runtime needs rebuilding. The package build runs it once, on Ubuntu 22.04, the
  older glibc of the two packages; `msb` links only glibc. In a source
  checkout, run it once yourself.
- **MDT's relay** (`native/mdt_relay`) is built by `scripts/build-relay.sh`
  into the same folder, as `bin/mdt-relay`. It has no dependencies, so its
  build needs no network.
- **A home per identity:** the VM, images and msb's SSH keys live in the
  identity's sandbox folder (`…/sandbox/microsandbox`), not
  `~/.microsandbox`. An `msb` you install, at any version, neither sees
  MDT's VMs nor migrates their database, and one identity's VM never sees
  another's. `MSB_HOME` is a short link to that folder, beside the
  identity's sockets (see [The VM runs in a bubble](#the-bubble) for why).
  Every call also sets `MSB_PATH`, the binary VMs are spawned with.
- **Launcher:** `…/sandbox/bin/msb` runs MDT's `msb` with that home, to
  look at the VM and go into it while it runs. The Zed SSH config uses it,
  and so can you (`… ls`). It refuses what starts, stops or changes the VM.
  MDT rewrites it on start, so its path survives an update that moves the
  runtime.
- **Never** the `msb` on your PATH: MDT has no fallback to it.
- **Upgrading microsandbox** means rebasing the fix in the fork onto the
  new release, then changing the commit, `UPSTREAM` and the two checksums in
  the script. A VM keeps running on the binary it started with until it is
  stopped. A newer `msb` may migrate the database in MDT's home, so going
  back to an older one isn't safe.

### Shared folders

- You pick each folder. It's mounted at the same path as on the host,
  read-only unless you choose read-write, which asks first: what the VM
  writes there can run on your machine when you use that folder.
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

A [runtime fix](../priv/sandbox/microsandbox-live-sharing.md), first a local
patch and now a commit in MDT's fork, retains those normal metadata caches and returns `ESTALE` for stale Linux
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
- After each boot the VM copies `memo` into it from `/mnt/mdt/bin/memo`
  (yours, put there by MDT), and runs `memo init` when it holds no memory:
  both in `/mnt/mdt/bin/mdt-boot`, inside the VM. MDT writes nothing into
  the folder except a copy of your memory when you ask for one.
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
  file grants), the VM's OptMem, and the Home, Cache and Work disks. Home
  holds the VM's own logins (Codex, Claude). Its snapshots sit next to it,
  readable by you only. On this machine the disk itself is encrypted.

Per identity too, not encrypted: its microsandbox home (the VM, images,
msb's SSH keys), its disks and its launcher, all in its sandbox folder.

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
    - grants that are on, with time left.
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

Each has one job. They sit under `lib/mdt_client/sandbox/` (brought up to
date on 2026-11-13, after step 5).

| Module                                  | Job                                                                                   |
| --------------------------------------- | ------------------------------------------------------------------------------------- |
| `Server`                                | The process of one identity's sandbox: holds the state, takes every message           |
| `Server.State`                          | Changing that state and telling the pages, the log, saving it sealed, timers, tasks   |
| `Server.Grants`                         | Building and checking a grant, turning it on, allowances, expiry by the clock         |
| `Server.Approvals`                      | What waits for you: holding, joining retries, your decision, giving up                |
| `Server.Values`                         | The real values, stored or minted, and answering the proxy with them                  |
| `Server.HostRuns`                       | A command on this machine: the ask, the run, its output                               |
| `Server.Machine`                        | The VM in its bubble, its disks and their copies, the image's builds                  |
| `Policy`                                | Whether a use goes through, asks or is refused: a pure function                       |
| `Placeholder`                           | Finding a placeholder in headers and putting the value in its place, Basic included   |
| `Grant`, `Allowance`, `Approval`        | The records of access, of a standing yes, and of what waits for you                   |
| `Presets`                               | The grant types and the presets that fill their form                                  |
| `Egress`, `Egress.Connection`           | The proxy on its socket; one connection from CONNECT to close, tunnelled or read      |
| `Destinations`                          | Which addresses are reserved, private or public, and a network grant's entries        |
| `Dns`                                   | The VM's lookups, passed to your resolver and logged                                  |
| `CertificateAuthority`, `Roots`         | MDT's CA and the certificates it makes; the system's roots for MDT's own connections  |
| `Describe`, `GraphQL`                   | A request as facts and claims                                                         |
| `RequestView`                           | A held request in full, and as curl or HTTP to copy                                   |
| `Shown`                                 | Text the VM chose, made to show all it holds                                          |
| `Channel`                               | The vsock socket behind the `mdt` command                                             |
| `HostCommand`, `HostRun`                | Checks and describes an ask to run a command; runs an approved one                    |
| `HostInfo`                              | What agents are told about this machine (`mdt host`, `host.md`)                       |
| `Bubble`, `Sockets`                     | The confined process the VM runs in; the sockets it reaches MDT through               |
| `Msb`, `VM`                             | The `msb` commands and the per-identity home; the VM's record                         |
| `Disks`, `Snapshot`                     | The VM's Home, Cache and Work disks; a copy of Home                                   |
| `Image`, `Build`                        | Building the image with podman; one build's record                                    |
| `Settings`, `Share`, `Shares`           | The VM's settings and their checks; shared folders and their mounts                   |
| `Inbox`, `Instructions`                 | What the VM reads at `/mnt/mdt`; the text agents are given                            |
| `Memory`                                | The VM's own OptMem folder and its seeding                                            |
| `Project`, `Projects`, `Guest`          | A repository with a copy in the VM; what the pages and the channel call; the VM's side |
| `HostGit`, `Sync`, `Handoff`            | git on your repository, bounded; your branches into the VM; the VM's work back        |
| `Event`                                 | One line of the activity log                                                          |
| `DesktopNotice`                         | The desktop notification's text for a waiting approval                                |

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
   network grant off closes its open connections. Expiry is read from the
   clock at every decision, for grants and allowances alike, so it also
   holds across a restart and a suspend; timers only refresh the screens,
   and the clock is looked at again when MDT starts and every 30 seconds.
6. A locked MDT swaps nothing. A stopped MDT leaves the VM without internet.
7. Nothing in the VM can reach MDT's web server. The agent channel offers only
   reading the grants (never values) and the host's description, asking for
   a grant, and asking to run a command.
8. Nothing in the VM can approve its own requests.
9. Nothing runs on the host for the VM without your approval of its exact
   text, each time. What runs is the text on the card.
10. Forwarding opens nothing from the VM to your machine, and listens only on
    the VM's own loopback address.

Added by the [first release](#first-release), each checked on a real VM:

11. The process running the VM has namespaces of its own (user, mount,
    network, PID, IPC), sees nothing of your home folder but msb's own
    store and no `/run`, and has no network
    interface but loopback. Read from `/proc`.
12. Every DNS query from the VM reaches MDT and is logged. A query aimed at
    another resolver gets no answer.
13. MDT writes nothing into storage the VM can write: its disks, its OptMem
    folder, read-write shares.
14. With no command grant, nothing in the VM can ask to run anything on your
    machine.

Added by step 5, each checked in the suite (`policy_test.exs`,
`hostile_text_test.exs`, `egress_corpus_test.exs`, `guarantees_test.exs`):

15. Whether a use goes through, asks or is refused depends only on the
    grants, the use and the clock. For every combination of grant state,
    allowances, host and placeholder: no placeholder goes to a host its
    grant doesn't list, nothing is let through or asked about for a grant
    that is off by the clock, an allowance past its time allows nothing, a
    reserved address opens only for an entry naming that very address, and
    a command is never let through unasked.
16. What an approval, the log, a notification or a page shows of the VM's
    text is UTF-8 and holds nothing that doesn't show. A script that does
    is refused.
17. Nothing the VM sends in an ask, a request or a repository makes the
    sandbox's process fail or MDT read without limit.
18. A request two parsers could read two ways goes out with no real value:
    it is refused whole, or reaches the host as one request with the head
    MDT wrote.

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
- Desktop notifications elsewhere than GNOME (KDE, macOS), and a sound or
  urgency per kind of approval.
- A second VM backend from stock parts (QEMU or Cloud Hypervisor, virtiofsd,
  vsock; spiked in `test/review/vm_spike`): folders added while the VM runs,
  connections from your machine into it, file sharing in a process per
  folder, no fork to carry.
- A seccomp filter on the bubble.
- MDT's Git tool on repositories in the VM, by running git inside it.
- Bringing a branch out of the VM when the repository has no remote.
- A published default image, so podman is needed only to change it.
- Names beside addresses in the activity log, read from the DNS answers.
