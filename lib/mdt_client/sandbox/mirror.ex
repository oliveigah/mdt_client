defmodule MDTClient.Sandbox.Mirror do
  @moduledoc """
  A project's mirror: its main worktree in the VM, `/work/<name>`, kept
  equal to your default target branch as committed.

  Your target branches travel as `refs/remotes/host/<branch>`, through
  git's own protocol over msb's pipe (`MDTClient.Sandbox.Guest`), and
  `host/HEAD` names the default one, so in any worktree of the project
  `git merge host` catches up with it. Only committed work goes; nothing
  of your working tree, and none of your other branches.

  The mirror is view only. Agents are told so, but they run as root in the
  VM, so nothing stops them. Before each update, whatever was changed or
  committed in the mirror is kept on a branch of its own, `rescued/<time>`,
  and the mirror is then put back exactly on your branch. Nothing is lost
  and the mirror stays exact.

  `run/2` does one update. `MDTClient.Sandbox.Server` runs it while the VM
  runs, each time a target branch of yours moves (`tips/1`).
  """

  alias MDTClient.Sandbox.{Guest, HostGit, Project, Shown}

  @type result :: %{
          tips: %{String.t() => String.t()},
          default: String.t(),
          rescued: String.t() | nil
        }

  # Makes the repository when there is none, and keeps what was done in the
  # mirror on a branch of its own: changes, or commits your branch doesn't
  # have. Prints that branch's name, or nothing.
  @prepare """
  set -e
  m=$1 d=$2
  if [ ! -d "$m/.git" ]; then mkdir -p "$m"; git init -q "$m"; fi
  cd "$m"
  dirty=$(git status --porcelain --untracked-files=all | head -n 1)
  ahead=""
  if git rev-parse -q --verify "refs/remotes/host/$d" >/dev/null && git rev-parse -q --verify HEAD >/dev/null; then
    ahead=$(git rev-list -n 1 "refs/remotes/host/$d..HEAD")
  fi
  if [ -n "$dirty" ] || [ -n "$ahead" ]; then
    kept="rescued/$(date -u +%Y%m%d-%H%M%S)"
    git checkout -q -b "$kept"
    git add -A
    git -c user.name=MDT -c user.email=mdt@localhost commit -q --no-verify -m "Edits found in the mirror, kept by MDT" || true
    echo "$kept"
  fi
  """

  # Drops the branches that are no longer targets, points host/HEAD at the
  # default, and puts the mirror on it. The branch keeps your branch's name,
  # unless an agent worktree has that name checked out.
  @finish """
  set -e
  m=$1 d=$2
  shift 2
  cd "$m"
  for ref in $(git for-each-ref --format='%(refname)' refs/remotes/host/); do
    b=${ref#refs/remotes/host/}
    [ "$b" = HEAD ] && continue
    keep=""
    for a in "$@"; do [ "$a" = "$b" ] && keep=1; done
    [ -n "$keep" ] || git update-ref -d "$ref"
  done
  git symbolic-ref refs/remotes/host/HEAD "refs/remotes/host/$d"
  git checkout -q -f -B "$d" "refs/remotes/host/$d" 2>/dev/null || git checkout -q -f --detach "refs/remotes/host/$d"
  git clean -q -fd
  """

  @doc "Where your target branches are now: branch name to commit. A branch that is gone is left out."
  @spec tips(Project.t()) :: %{String.t() => String.t()}
  def tips(%Project{path: path, targets: targets}) do
    refs = Enum.map(targets, &"refs/heads/#{&1}")

    case HostGit.run(path, ["for-each-ref", "--format=%(objectname) %(refname)" | refs]) do
      {:ok, output} ->
        for line <- String.split(output, "\n", trim: true),
            [sha, "refs/heads/" <> branch] <- [String.split(line, " ", parts: 2)],
            into: %{},
            do: {branch, sha}

      {:error, _} ->
        %{}
    end
  end

  @doc "Updates the mirror of `project` in the VM behind `guest`."
  @spec run(Project.t(), Guest.t()) :: {:ok, result()} | {:error, String.t()}
  def run(%Project{path: path, default_target: default} = project, guest) do
    mirror = Project.mirror_path(project, guest)
    tips = tips(project)

    with true <- Map.has_key?(tips, default) || {:error, "Your branch #{default} is gone."},
         {:ok, kept} <- exec(guest, @prepare, [mirror, default]),
         {:ok, _} <- push(path, guest, mirror, Map.keys(tips)),
         {:ok, _} <- exec(guest, @finish, [mirror, default | Map.keys(tips)]) do
      kept = String.trim(kept)
      {:ok, %{tips: tips, default: default, rescued: if(kept == "", do: nil, else: kept)}}
    end
  end

  defp exec(guest, script, args) do
    case guest.exec.(["sh", "-c", script, "mdt-mirror" | args]) do
      {:ok, output} -> {:ok, output}
      {:error, text} -> {:error, "The mirror could not be updated: " <> Shown.text(text)}
    end
  end

  # Forced: your branch may have been rewritten. Your pre-push hooks are for
  # your remotes, not for this.
  defp push(path, guest, mirror, branches) do
    specs = Enum.map(branches, &"+refs/heads/#{&1}:refs/remotes/host/#{&1}")

    HostGit.run(path, ["push", "--porcelain", "--no-verify", guest.git_url.(mirror) | specs],
      env: guest.env,
      seconds: 600
    )
  end
end
