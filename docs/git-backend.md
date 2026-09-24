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
- tags, resolved through annotated tag objects to the commits they name;
- commits in topological order, with parents, author and committer metadata,
  message, and every label pointing at the commit, branch or tag;
- HEAD and detached-state information; and
- a merge, rebase, cherry-pick, revert, or bisect operation currently in
  progress.

The graph result describes topology through each commit's ordered `parents`
list. Lane assignment and edge routing belong in the client because they depend
on viewport and rendering choices. The default graph window is 500 commits and
can be changed with `snapshot(repository, limit: count)` up to 5,000.

Signatures are left unchecked in a snapshot: their commits carry
`signature_status: nil`. Checking one runs gpg or ssh-keygen, once per signed
commit, and on a repository that signs its history that costs more than the
rest of the snapshot put together. `signature/2` checks one commit, which is
what the inspector shows; `get_commit/2` and `snapshot(repository, signatures:
true)` fill the fields in as well.

`list_branches/1`, `graph/2`, and `get_commit/2` expose the same data separately
for targeted refreshes.

## Mutations

The core currently supports:

- cloning a remote repository into an empty folder;
- creating, checking out, renaming, and deleting local branches;
- checking out a remote branch into a local tracking branch;
- detached commit checkout;
- commit, merge, rebase, cherry-pick, revert, and soft or hard reset;
- staging and unstaging an exact selection of repository files;
- discarding every change to an exact selection of repository files;
- path-limited stash creation plus stash listing, application, popping, and
  deletion;
- editing HEAD or an older commit message on the checked-out branch;
- squashing consecutive commits on the checked-out branch into one;
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
The rebase names the branch rather than HEAD's id, so the branch moves with the
rewrite instead of being left behind on a detached HEAD.

Squashing works the same way. The commits must follow one another on the
branch's first-parent line with no merge among them; the replacement takes the
newest one's tree, the oldest one's parent and author, and a new message, and
everything after the newest is replayed on top of it.

## File boundary

`MDTClient.Git.Files` owns the working tree. `status/1` lists the changed
repository paths as `MDTClient.Git.FileChange` structs:

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

`commit_status/2` answers the same question for history: the paths one commit
changed, in the same `FileChange` shape, with the kind of change in `staged`
because everything in a commit is recorded. A merge is compared against its
first parent, which is what it brought onto the branch.

`diff/3` reads one path at a time, on one side of the index, or the change a
commit made to it with `commit: revision`:

```elixir
{:ok, diff} = MDTClient.Git.Files.diff(repository, "lib/app.ex", side: :staged)
```

It returns a `MDTClient.Git.FileDiff` holding `MDTClient.Git.DiffHunk`s of
`MDTClient.Git.DiffLine`s, each line carrying the numbers it has on both sides.
An untracked path has nothing in the repository to compare against, so passing
`untracked: true` reads it against an empty file instead. A binary file is
flagged rather than rendered, and `:lines` caps how much is parsed so opening a
generated file cannot flood the caller. Diffs are read on request, never as part
of a snapshot, so branch and graph refreshes stay cheap.

File editing is deliberately still absent. Stage, unstage, discard, and
path-limited stash remain in `Git.Core`: they accept only repository paths and
perform Git index or object database mutations. Keeping
file content outside the core lets graph and branch state refresh independently
from larger diff payloads, while both APIs share the same repository handle and
command runner, so a tab's SSH credentials apply to either.

## Client

`MDTClientWeb.GitLive` is the only consumer. It keeps one repository handle per
tab, runs every command through `start_async/3` — refreshing the snapshot,
status, and stash list in the same task — and turns a `%Error{kind: :conflict}`
into the continue, skip, and abort panel. Picking a commit or opening a diff is
lighter: only the commit's files and signature, or the diff, are read, in a
task of their own that reloads nothing else. While a command runs such a read
waits, because the command's own refresh answers it.

The page is kept cheap to patch however large the repository. Every patch walks
the whole LiveView, so the graph only puts the rows around the viewport on the
page, with spacers standing in for the rest, and a hook asks for the next rows
as the reader scrolls; a commit limit of 5,000 costs a click what 500 does.
The graph, branch and file lists hand each row what the rest of the page says
about it — picked, menu open, HEAD — and are keyed, so a click sends the rows
it changed rather than the whole list. Lane assignment lives in
`MDTClientWeb.GitLive.Graph.Layout`, a pure function from the commit list to
rows, lanes, and edges.

A local branch and the remote branches of the same name on one commit share a
single label: the bare name, with quiet marks on its right for where it lives (a
monitor for this machine, a cloud for a remote) and a tick on its left when HEAD
is on it. Picking that label, or opening its menu, means the local branch; the
remote one stays reachable from the branch panel. Refs pointing at the same
commit then collapse to the one that matters most — the
branch HEAD is on, then master, main or dev, then the rest, then tags — with the
others dropping down on hover, and a right click on any of them opening that
branch's menu. A name too long for the column is cut short, and hovering it
drops down the same list with the name in full. The graph is the primary surface: a right click, a row menu, or the inspector's
Actions button opens the same commit menu, and every entry maps to one `Core`
call. A dirty worktree takes a row of its own above the newest commit, drawn by
`Layout.pending_row/1`, and opening a file diff replaces the graph until it is
closed. The open folders are remembered by `MDTClientWeb.GitLive.Session`, and a timer
refreshes the active tab so work done outside MDT appears on its own. Selecting
a commit lists the files it touched under its metadata, and picking one of them
opens the same diff view; the working tree keeps a tab of its own. Its files are
picked the way a file manager picks them: a click takes one, Ctrl or Cmd adds or
drops one, Shift takes the run from the file clicked last, across both lists,
and Ctrl+A takes them all. A right click opens what can be done to the pick,
each entry counting the files it would touch. Commits in the graph are picked
the same way, and a right click on a pick of several offers to cherry-pick them
all, oldest first, or to squash them under a message that starts as theirs
combined. A squash the backend would refuse is shown disabled, with the reason. Folder selection goes through the Tauri dialog plugin; because the window loads
the local Phoenix server over loopback, that call is only permitted by the
`local-server` capability described in `README.md`. The same chooser offers
`Core.clone/3` for a repository that is not on this machine yet, and falls back
to a typed path where the picker cannot run at all, such as a browser.
