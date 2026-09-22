# Git backend

`MDTClient.Git.Core` is the interface between the future LiveView and Git. It
uses the installed `git` executable directly through `System.cmd/3`; arguments
are always passed as an argv list and never interpolated into a shell command.

## Repository tabs

Opening a folder returns an immutable `MDTClient.Git.Repository`. Its `path` is
normalized to the worktree root, even when the user selected a nested folder.
The handle also contains the worktree Git directory, common Git directory, and
an optional validated SSH key pair. A UI tab should keep one of these handles
as its identity and pass it to every other call.

The selected private key is supplied to Git through `GIT_SSH_COMMAND` only for
commands using that repository handle. The public key is used to verify that
the chosen files form a pair before they are saved. MDT stores their paths, not
their contents. The key applies to SSH remote authentication without mutating
the application environment.

```elixir
{:ok, repository} = MDTClient.Git.Core.open("/projects/example")

{:ok, repository} =
  MDTClient.Git.Core.with_ssh_keys(
    repository,
    "/home/me/.ssh/id_ed25519",
    "/home/me/.ssh/id_ed25519.pub"
  )
```

SSH keys only work with SSH remote URLs. `list_remotes/1` reports each remote's
transport and offers the equivalent `git@host:path` URL for HTTP(S) remotes.
`use_ssh_remote/2` applies that conversion to an existing remote.

## Read model

`snapshot/2` is the normal refresh entry point. It returns:

- local and remote branches, including the current branch, upstream, ahead and
  behind counts, target commit, and symbolic remote references;
- commits in topological order, with parents, author and committer metadata,
  message, signature state, and every branch label pointing at the commit;
- HEAD and detached-state information; and
- a merge, rebase, cherry-pick, revert, or bisect operation currently in
  progress.

The graph result describes topology through each commit's ordered `parents`
list. Lane assignment and edge routing belong in the client because they depend
on viewport and rendering choices. The default graph window is 500 commits and
can be changed with `snapshot(repository, limit: count)` up to 5,000.

`list_branches/1`, `graph/2`, and `get_commit/2` expose the same data separately
for targeted refreshes.

## Mutations

The core currently supports:

- creating, checking out, renaming, and deleting local branches;
- checking out a remote branch into a local tracking branch;
- detached commit checkout;
- commit, merge, rebase, cherry-pick, revert, and soft or hard reset;
- staging and unstaging an exact selection of repository files;
- path-limited stash creation plus stash listing, application, popping, and
  deletion;
- editing HEAD or an older commit message on the checked-out branch;
- fetch, pull, push, remote URL changes, and remote branch deletion; and
- continue, skip, and abort for operations that stop on conflicts.

Successful mutations return `{:ok, %MDTClient.Git.CommandResult{}}`. The UI
should request a new snapshot afterward. Command failures return
`{:error, %MDTClient.Git.Error{}}`. If Git stopped for conflict resolution, the
error kind is `:conflict` and its `operation` field has the state needed by an
action panel.

Editing an older commit creates a replacement commit and rebases its descendants
with merge topology preserved. This requires a clean worktree, the target must
be an ancestor of HEAD, and HEAD must be attached to a branch. Like any history
rewrite, it changes descendant object IDs and can stop for conflict resolution.

## File boundary

`MDTClient.Git.Files` owns the working tree. Today it exposes one read-only
function, `status/1`, which lists the changed repository paths as
`MDTClient.Git.FileChange` structs:

```elixir
{:ok, changes} = MDTClient.Git.Files.status(repository)
```

Each change carries its path, the original path when Git detected a rename, and
the state of both sides: `staged` is the difference between HEAD and the index,
`unstaged` the difference between the index and the working tree. Either is
`nil` when that side is unchanged, so a path can belong to the staged list, the
unstaged list, or both. Untracked and conflicted paths are flagged separately
because they need different actions. The underlying command is
`git status --porcelain=v2 -z`, whose NUL terminated records keep file names
with spaces, quotes, or newlines intact.

Diffs, file contents, editing, and discard are deliberately still absent. Stage,
unstage, and path-limited stash remain in `Git.Core`: they accept only
repository paths and perform Git index or object database mutations. Keeping
file content outside the core lets graph and branch state refresh independently
from larger diff payloads, while both APIs share the same repository handle and
command runner, so a tab's SSH credentials apply to either.

## Client

`MDTClientWeb.GitLive` is the only consumer. It keeps one repository handle per
tab, runs every command through `start_async/3` — refreshing the snapshot,
status, and stash list in the same task — and turns a `%Error{kind: :conflict}`
into the continue, skip, and abort panel. Lane assignment lives in
`MDTClientWeb.GitLive.Graph.Layout`, a pure function from the commit list to
rows, lanes, and edges.

The graph is the primary surface: a right click, a row menu, or the inspector's
Actions button opens the same commit menu, and every entry maps to one `Core`
call. Folder selection goes through the Tauri dialog plugin; because the window
loads the local Phoenix server over loopback, that call is only permitted by the
`local-server` capability described in `README.md`. When the picker cannot run
at all — a browser, say — the UI falls back to a dialog asking for a path.
