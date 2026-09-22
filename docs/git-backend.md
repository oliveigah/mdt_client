# Git backend

`MDTClient.Git.Core` is the interface between the future LiveView and Git. It
uses the installed `git` executable directly through `System.cmd/3`; arguments
are always passed as an argv list and never interpolated into a shell command.

## Repository tabs

Opening a folder returns an immutable `MDTClient.Git.Repository`. Its `path` is
normalized to the worktree root, even when the user selected a nested folder.
The handle also contains the worktree Git directory, common Git directory, and
an optional SSH agent socket. A UI tab should keep one of these handles as its
identity and pass it to every other call.

The selected socket is supplied to Git as `SSH_AUTH_SOCK` only for commands
using that repository handle. It therefore applies to remote authentication and
to commit signing when the repository is configured to use SSH signing. It does
not mutate the application environment or affect other tabs.

```elixir
{:ok, repository} =
  MDTClient.Git.Core.open("/projects/example",
    ssh_auth_sock: "/run/user/1000/keyring/ssh"
  )

{:ok, repository} =
  MDTClient.Git.Core.with_ssh_agent(repository, "/tmp/ssh-agent.sock")
```

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
- fetch, pull, push, and remote branch deletion; and
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

Working-tree status, diffs, discard, and file-content access will live in
`MDTClient.Git.Files`. Stage, unstage, and path-limited stash remain in
`Git.Core`: they accept only repository paths and perform Git index or object
database mutations. Keeping file content outside the core lets graph and branch
state refresh independently from larger diff payloads, while both APIs can
continue to share the same repository handle and command runner.
