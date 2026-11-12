# Microsandbox live-sharing fix

The patch beside this file targets Microsandbox **v0.7.14**, commit
`60fc5071b34e6cc2671c84c8dc07709795d45d27`. It is a local runtime patch;
no upstream release or installation is implied.

Host atomic replacements previously made cached guest inode references return
ENOENT. Git treated the apparently missing index as empty. Our live probe
reproduced this on all 100 host-side index replacements.

The patch:

- Retains Microsandbox's normal five-second entry/attribute caches. The
  earlier zero-timeout policy was removed after excessive CPU use was measured.
- Keeps buffered I/O and invalidation on open; it does not select DIRECT_IO,
  so applications using mmap remain supported.
- Returns ESTALE for an obsolete Linux inode reference, allowing pathname
  operations to retry lookup. Host errors such as EACCES, EIO and EMFILE
  remain errors rather than being hidden as missing files.
- Preserves existing open handles and valid hard-link aliases.

This changes live runtime behavior, without changing saved configuration,
wire messages, metadata formats, snapshots or firmware. It takes effect when
the VM starts under the patched runtime. Replacing the CLI does not replace
the already-running VM process. The earlier debug build plus uncached metadata
and one-second polling consumed about 5.8 host CPU cores during a 20-second
sample. The replacement uses an optimized release build, normal caching and
five-second polling. See the post-restart validation below for the measured results.

MDT separately configures Zed's remote server with
`ZED_FILE_WATCHER_MODE=poll` and `ZED_FILE_WATCHER_POLL_MS=5000`. Host writes
still do not generate guest inotify mutation events. Other development
watchers need their own polling configuration or separate validation.

## Build and apply on the host

The candidate is under `tmp/microsandbox-sharing-runtime/msb`. The installer
now requires a release-build marker and rejects the earlier debug candidate.
For an optimized native build, run:

```sh
bash scripts/build-microsandbox-sharing.sh
```

The Linux build script pins and patches its own source checkout under `tmp`, runs
the filesystem suite, and builds the CLI. Cargo downloads the matching
prebuilt guest agent; the patch does not change that agent or firmware.
It needs Git, a recent Rust/Cargo toolchain, a C compiler, and internet access
to the public source/artifact registries.

Install from a **host terminal**, passing the sandbox name shown by MDT:

```sh
bash scripts/install-microsandbox-sharing.sh SANDBOX_NAME
```

An optional second argument selects the existing `msb` executable explicitly.
The installer verifies the candidate and patch checksums, accepts only v0.7.14, saves the original as
`msb.before-mdt-sharing`, atomically installs the candidate and sets polling
in the VM's saved environment. It does not stop the VM. If the candidate
cannot run on the host, it builds natively first.

Stop and start the sandbox in MDT, then reconnect Zed. This ends any active
agent commands in that VM. The existing Home/Cache and project mounts are
kept. An image rebuild is unnecessary for the live check; future image
builds and MDT's shell profile also carry the polling defaults.

## Validation

The earlier uncached variant passed live host-to-VM validation on 2026-11-12 after installation and a VM
restart: zero failed content/index/lock checks, including all 100 host-side
Git index replacements. Evidence:
`tmp/sandbox-sharing-probes/cross-j1wi5zdm/cross-results.json`.
The user also confirmed automatic host-to-Zed refresh.

The cached, optimized variant passed a fresh live host-to-VM check after the
2026-11-12 restart, with zero failed content/index/lock checks and all 100
immediate host-side Git index replacements passing. Evidence:
`tmp/sandbox-sharing-probes/cross-wkfzn7om/cross-results.json`.
Only the project directory was shared, read-write. The running Zed remote
server had polling enabled at 5000 ms. A 20-second guest sample before the
app checks showed 3.5% total CPU utilization across 12 vCPUs; the main Zed
remote server used 10.8% of one core and 84.3 MiB RSS. Guest CPU does not
measure the host runtime's CPU cost.

The user then ran a separate 20-second sample on the host, saved in
`tmp/sandbox-host-resource-usage.json` (its top-level `guest` label is an
artifact of invoking the sampler without `--sandbox`). The VM process used
77.6% of one core and 2255 MiB RSS, versus 578.6% and 2370.9 MiB in the
earlier sample: about 87% less VM CPU. Total host CPU utilization was 6.6%
across 24 logical CPUs. These were separate live samples, not a controlled
benchmark; the remaining roughly 0.78-core VM cost is still noticeable.

Before the patch, the new file and directory replacement tests failed with
ENOENT instead of ESTALE. With the patch, all five new regressions and all
680 filesystem unit tests passed. The full CLI compiled and reported
`msb 0.7.14`. These checks do not replace the live cross-host check.

The 60 VM-construction tests also passed. The broader upstream runtime suite
was not clean in this VM: writer/mmap detection and crash-membership tests
failed on both the patched and unpatched source, and the patched parallel
run also observed a cache-age test failure. These failures are retained in
the diagnostic logs; they were not changed or hidden by the patch.

MDT's `mix precommit` passed all 624 checks with system/global Git config
isolated (`GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null`). The sandbox's
system SSH-to-HTTPS rewrite otherwise changes two Git URL test expectations.
An Elixir 1.20 compiler warning was fixed by pinning the outer bitstring-size
variable, and the grant-duration test now checks its actual deadline rather
than requiring an exact countdown string across a clock-second boundary.

For the cached release candidate, all 680 filesystem tests and six focused
shell/inbox tests passed. The optimized CLI built successfully and reports
`msb 0.7.14`. A full app check during debug-VM/build load passed 519/624 checks;
the remaining 105 all exceeded existing 100 ms async deadlines. These are
not reported as passing. Logs and the before-change CPU sample are under
`tmp/microsandbox-sharing-runtime/validation-cached-release`.

After the restart, the full `mix precommit` passed: 624 checks (5 doctests,
619 tests), with 3 excluded. System/global Git config was isolated as above.
The log is `validation-cached-release/mdt-sharing-post-restart-precommit.log`
under the same runtime directory.

After restarting the VM under the new runtime, run on the host:

```sh
python3 scripts/sandbox_shared_fs_probe.py check --sandbox SANDBOX_NAME
```

The host command launches the guest half with `msb exec` and runs the host
half itself. It uses new disposable files and repositories under
`tmp/sandbox-sharing-probes`; it does not change the project's index.
It allows up to ten seconds for file-content visibility and records the
observed delay, including size-changing writes. The 100 host-side Git index
replacement checks remain immediate and strict. It exits nonzero when any
content/index/lock check fails. Raw inotify observations are reported separately
because Zed now uses polling. Confirm the remote-server environment and
automatic editor refresh after reconnecting as a separate UI check.

For rollback, stop the sandbox, atomically restore the saved runtime backup,
and start the sandbox again. The polling environment can remain enabled.

## Refresh and access scope

These are live mounts, not two copies synchronized by a background copier.
Save a file before checking it from the other side. Normal metadata caching
and five-second polling allow a few seconds of display lag; scan time can
add further delay.

`git status` refreshes Git's view in whichever terminal runs it. In Zed's
command palette, `editor: reload file` reloads the active file from disk
(save wanted edits first). `workspace: reload` is a heavier restart/reload
of the editor. `sync` flushes pending writes; it does not invalidate the
VM's metadata cache or refresh the editor. There is no generic cross-side
force-refresh command for these mounts.

For this session's intended scope, set MDT's shared folders to exactly
`/home/oliveigah/projects/mdt/mdt_client`, read-write. Remove the broader
`/home/oliveigah/projects/mdt` and `/home/oliveigah/projects/msb_test` shares
before adding it, because overlapping shares are refused. Recreate the VM
with Home and Cache kept to apply that mount change. This is a host-side MDT
setting; editing files inside the VM does not change its grants or mounts.
