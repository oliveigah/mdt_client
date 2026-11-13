# To do

Features set aside, with what is known about them, so they can be picked up
again without starting over.

## Port forwarding from the VM

Dropped on 2026-11-13 while you think about it. Nothing forwards the VM's
ports now: a server an agent starts in the VM can't be reached from your
machine, and `mdt ports` is gone.

The code was added in `4203d5a` ("feat: vm loopback") and was last whole in
`4cccb2b`: `MDTClient.Sandbox.Ports`, `…Forwarder`, `…Forwarder.SSH`, the
overview's "Ports on this machine" card, the `ports` ask on the agent
channel, the "Servers you start" parts of `host.md` and the agents'
instructions, and their tests (`ports_test`, `forwarder_test`,
`sandbox_live_ports_test`, `FakeTunnel`).

### What was built

A server an agent starts in the VM shows up on your machine by itself. A
Phoenix server on port 4000 in the VM is `http://127.77.12.34:4000` here
within a few seconds, and goes away when it stops.

#### The address

- Each identity's VM has a fixed address on your machine, `127.77.X.Y`,
  derived from the identity. Linux sends all of `127.0.0.0/8` to loopback,
  so it needs no setup. Ports keep their numbers without colliding with
  your machine's own: your `localhost:4000` stays yours.
- The overview showed the address and the ports up there. Agents learn it
  from `mdt host` (`/mnt/mdt/host.md`), and `mdt ports` lists what is
  forwarded, so they can give you the URL.
- No name for it. A name needs root once (`/etc/hosts`), and dev servers
  that check the Host header (Vite, Rails, Django) refuse unknown names but
  accept addresses. `*.localhost` names always go to `127.0.0.1`, which
  brings the collisions back.
- Browsers treat the address as a site of its own, so the VM's pages never
  see the cookies of your other local apps, and as a secure context (all of
  `127.0.0.0/8` is), so service workers and WebAuthn work.

#### What is forwarded

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

#### How it works

- MDT keeps one SSH connection to the VM: OpenSSH as a control master,
  through `msb ssh serve VM --stdio`. msb's SSH server carries forwarded
  connections (`direct-tcpip`) over its own channel to the VM's agent, which
  connects inside the VM; the VM's network isn't involved. Forwards are
  added and removed on that connection (`ssh -O forward|cancel`).
- The listing ran apart from it, as `msb exec VM --user root -- ss -ltnpH`
  every 2 seconds: see [The msb SSH bug](#the-msb-ssh-bug).
- It uses a key of its own, made on first use in the identity's sandbox
  folder and added with `msb ssh authorize` on each start. It reads no
  `~/.ssh/config` (`-F /dev/null`) and never prompts (`BatchMode`).
- It runs while the VM runs. If the connection drops, MDT connects again
  every few seconds. Stopping the VM, locking MDT or quitting it ends the
  connection, and its forwards with it; if MDT dies, a wrapper ends ssh.
- Not msb's own published ports (`--port`): each new one needs a restart,
  and they arrive on the VM's network interface, so servers on the VM's
  loopback can't be reached.

#### Safety

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

### The msb SSH bug

Why this came up: msb's SSH server (0.7.14 and 0.7.15, russh 0.65.0) never
frees a command's agent connection after the command ends, until the whole
SSH connection does.

- When a command exits, msb closes its channel itself. russh's
  `Session::close` sends CLOSE and forgets the channel (`src/session.rs:287`),
  so when the client's CLOSE comes back, russh finds no channel and returns
  before calling the handler's `channel_close` (`src/server/encrypted.rs:1444`).
  msb's cleanup lives there, so the command's `ExecControl` and stdin keep its
  agent connection open.
- The VM's agent relay takes 128 clients (`AGENT_RELAY_MAX_CLIENTS`,
  `crates/protocol/lib/lib.rs:115`). The 129th command fails and msb ends the
  session, with every forward on it.
- Listing every 2 seconds over the control master hit that in about 4
  minutes. Moving the listing to `msb exec`, which exits and frees its
  connection, worked around it, so MDT never shipped the patch.
- Forwarded TCP connections share the session's one agent connection, so
  they don't count toward the 128. Each one msb closes leaves a small entry
  until the session ends.
- A fix with 3 tests that need no VM sits in `~/projects/microsandbox` as
  the stash "ssh: release agent connections of channels msb closes". It is
  large for what it serves; reporting the bug upstream is yours to do. A
  write-up for the maintainers (cause, repro, fix sketch) is in
  `README-ssh-channel-leak.md` at that clone's root.

### What any design runs into

- Your machine can't reach the VM by address. msb's `--vsock` only goes from
  the VM to the host. The ways in are msb's agent (`msb exec`, `msb ssh
  serve` and its `direct-tcpip`) and msb's published ports (`--port`).
- Forwards are per port, so something must either know what listens in the
  VM or reserve a fixed set of ports ahead of time.

### Options

1. **Bring back what was built.** Works on stock msb. Costs one `msb exec`
   every 2 seconds per running VM, plus MDT's SSH key, control master and
   wrapper. The overview could show only the address and leave the list
   out.
2. **A fixed range published by msb**, such as
   `--port 127.77.X.Y:4000-4099:4000-4099` at create. No SSH, no polling,
   and the least code. But:
    - connections arrive on the VM's network address, not its loopback, so
      servers must listen on `0.0.0.0` in the VM; Phoenix dev and Vite
      default to `127.0.0.1`;
    - the range is held the whole time. A port in it that your machine
      already holds on every address stops the VM's network from starting
      (`crates/network/lib/engine/network.rs:393`), and while the VM runs,
      your own servers on every address can't use those ports;
    - changing the range means recreating the VM.
3. **Forward on request** over the SSH tunnel: an agent runs
   `mdt forward 4000`, or you type the port in the overview. No polling,
   servers on the VM's loopback work, and it still depends on SSH.
4. **A guest daemon of MDT's own.** A small static binary served from
   `/mnt/mdt/bin` (no image rebuild, works with any Containerfile), started
   as root with `msb exec --detach` after each start. It dials MDT on a
   vsock port of its own (5001) and stays connected:
    - it watches listeners inside the VM and tells MDT only what changed;
    - it carries forwards: MDT listens on the VM's address, asks it to open
      stream N, and it dials back with "stream N" and connects inside the
      VM;
    - one JSON-lines connection, so other introspection becomes another
      message type, and MDT needs no SSH at all.

   Costs: the binary (Rust; the msb build already needs cargo) for x86_64 and
   aarch64, MDT in the data path, and pairing streams. Any process in the VM
   can connect to the port and pretend to be the daemon, so MDT treats what
   it says as untrusted and keeps the same limits.

### To decide

- Whether reaching the VM's servers from your machine is needed often enough
  to carry any of these.
- For 2: the range, and whether agents binding `0.0.0.0` is acceptable.
- For 4: whether more introspection is coming, which is what would pay for
  it.
