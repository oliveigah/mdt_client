defmodule MDTClient.Sandbox.Handoff do
  @moduledoc """
  The VM's work back to you: one finished piece of work that an agent wraps
  up, names and describes, the way it would open a pull request.

  Work in progress in the VM stays in the VM. A handoff is one commit, fixed
  when it is made (`receive/3`): MDT fetches the worktree's branch as it is
  at that moment and records the commit it got. On your machine it sits as
  `vm/<branch>`, kept the way git keeps a remote's branches, and only while
  it waits.

  Your branches are yours. Nothing here commits, stages, or creates, moves
  or deletes a branch of yours. `bring/3` puts the whole change into your
  working tree as uncommitted changes, merged with what you have there;
  `undo/2` puts your working tree back.

  `title`, `body` and `agent` are the agent's words: claims. What MDT works
  out itself is in `facts/2`.
  """

  alias MDTClient.Sandbox.{Guest, HostGit, Project, Shown}

  @enforce_keys [:id, :project, :branch, :commit, :base, :title, :at]
  defstruct [
    :id,
    :project,
    :branch,
    :commit,
    :base,
    :title,
    :agent,
    :at,
    :note,
    :decided_at,
    :undo,
    body: "",
    status: :waiting
  ]

  @type status :: :waiting | :brought | :sent_back | :declined | :replaced

  @typedoc "What a bring changed, kept so it can be undone."
  @type undo :: %{snapshot: String.t(), paths: [String.t()], created: [String.t()]}

  @type t :: %__MODULE__{
          id: String.t(),
          project: String.t(),
          branch: String.t(),
          commit: String.t(),
          base: String.t(),
          title: String.t(),
          body: String.t(),
          agent: String.t() | nil,
          at: DateTime.t(),
          note: String.t() | nil,
          decided_at: DateTime.t() | nil,
          undo: undo() | nil,
          status: status()
        }

  @type facts :: %{
          commits: non_neg_integer(),
          messages: [String.t()],
          files: [
            %{path: String.t(), added: non_neg_integer() | nil, removed: non_neg_integer() | nil}
          ],
          added: non_neg_integer(),
          removed: non_neg_integer(),
          behind: non_neg_integer(),
          conflicts: [String.t()],
          hints: [String.t()]
        }

  @type refusal ::
          :not_in_a_project
          | :not_a_worktree
          | :detached
          | {:uncommitted, String.t()}
          | :bad_branch
          | :unrelated
          | :too_large
          | :no_title

  @title_limit 200
  @body_limit 16 * 1024
  # The most new data one handoff may bring into your repository, and the
  # most of its diff that is read to be shown.
  @size_limit_mib 1024
  @diff_shown 512 * 1024

  # Read in the VM, in the folder the agent named: the worktree's top, the
  # repository it belongs to, its branch, and what isn't committed.
  @look """
  cd "$1" 2>/dev/null || exit 3
  top=$(git rev-parse --show-toplevel 2>/dev/null) || exit 3
  common=$(cd "$(git rev-parse --git-common-dir)" && pwd -P)
  copy=$(cd "$2" 2>/dev/null && pwd -P)
  branch=$(git symbolic-ref --quiet --short HEAD || true)
  printf '%s\\n%s\\n%s\\n%s\\n' "$(cd "$top" && pwd -P)" "$common" "$copy" "$branch"
  git status --porcelain | head -20
  """

  # Files that run on your machine when you build, commit or open the
  # project. A hint for the card, not a review.
  @runs [
    {~r{(^|/)(mix\.exs|Makefile|GNUmakefile|makefile|justfile|Justfile|Rakefile|package\.json|build\.gradle(\.kts)?|build\.rs|Cargo\.toml|setup\.py|pyproject\.toml|CMakeLists\.txt)$},
     "which runs when you build"},
    {~r{(^|/)(\.envrc|\.tool-versions|mise\.toml|\.mise\.toml)$},
     "which your shell and tools read"},
    {~r{^(\.husky|\.githooks)/|(^|/)\.pre-commit-config\.yaml$}, "which runs when you commit"},
    {~r{^(\.vscode|\.zed|\.idea)/}, "which your editor reads"},
    {~r{^\.github/workflows/|(^|/)\.gitlab-ci\.yml$}, "which runs in CI"}
  ]

  @doc """
  Takes the handoff an agent asks for from `ask.cwd` in the VM: checks it is
  a worktree of the project's copy with everything committed, fetches its
  branch to `vm/<branch>`, and records the commit that arrived.

  `ask` holds the agent's words: `cwd`, `title`, `body`, `agent`.

  ## Options

    * `:size_limit_mib` - the most new data the branch may bring into your
      repository (1024); more is refused as `:too_large`
  """
  @spec receive(Project.t(), Guest.t(), map(), keyword()) ::
          {:ok, t()} | {:error, refusal() | String.t()}
  def receive(%Project{path: repo} = project, guest, ask, opts \\ []) do
    limit = Keyword.get(opts, :size_limit_mib, @size_limit_mib)
    title = ask |> Map.get(:title) |> shown() |> String.trim() |> String.slice(0, @title_limit)
    copy = Project.guest_path(project, guest)

    with true <- title != "" || {:error, :no_title},
         {:ok, branch} <- look(guest, text(Map.get(ask, :cwd)), copy),
         {:ok, _} <- fetch(repo, guest, copy, branch, limit),
         commit when is_binary(commit) <-
           HostGit.line(repo, ["rev-parse", "refs/remotes/vm/#{branch}"]),
         base when is_binary(base) <-
           HostGit.line(repo, ["merge-base", "HEAD", commit]) || {:error, :unrelated},
         id = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower),
         # MDT's own hold on the commit, which outlives vm/<branch>.
         {:ok, _} <- HostGit.run(repo, ["update-ref", "refs/mdt/handoffs/#{id}", commit]) do
      {:ok,
       %__MODULE__{
         id: id,
         project: project.name,
         branch: branch,
         commit: commit,
         base: base,
         title: title,
         body: ask |> Map.get(:body) |> shown() |> String.slice(0, @body_limit),
         agent: ask |> Map.get(:agent) |> shown() |> String.trim() |> String.slice(0, 60),
         at: DateTime.utc_now() |> DateTime.truncate(:second)
       }}
    else
      nil -> {:error, "The branch did not arrive."}
      {:error, reason} -> {:error, reason}
    end
  end

  # The branch comes in under a limit on what git may write, so a handoff
  # can't fill your disk through your own repository.
  defp fetch(repo, guest, copy, branch, limit) do
    started = System.os_time(:second)

    case HostGit.run(
           repo,
           ["fetch", "--no-tags", "--no-write-fetch-head", guest.git_url.(copy)] ++
             ["+refs/heads/#{branch}:refs/remotes/vm/#{branch}"],
           env: guest.env,
           seconds: 600,
           file_limit: limit
         ) do
      {:ok, output} ->
        {:ok, output}

      {:error, text} ->
        # The kernel stops the write (SIGXFSZ, signal 25), and git says so
        # one way or the other.
        if text =~ ~r/died of signal 25|File too large|File size limit exceeded/i do
          sweep(repo, started)
          {:error, :too_large}
        else
          {:error, text}
        end
    end
  end

  # What a fetch stopped halfway leaves in your repository: the files git
  # was still writing, up to the limit each. git would delete them itself,
  # two weeks later.
  defp sweep(repo, since) do
    case HostGit.line(repo, ["rev-parse", "--path-format=absolute", "--git-path", "objects"]) do
      nil ->
        :ok

      objects ->
        # Listed, not globbed: the path is yours and may hold any character.
        for dir <- [objects | Enum.map(ls(objects), &Path.join(objects, &1))],
            name <- ls(dir),
            String.starts_with?(name, ["tmp_obj_", "tmp_pack_", "tmp_idx_", "tmp_rev_"]),
            path = Path.join(dir, name),
            {:ok, %File.Stat{type: :regular, mtime: mtime}} <- [File.stat(path, time: :posix)],
            mtime >= since,
            do: File.rm(path)

        :ok
    end
  end

  defp ls(dir) do
    case File.ls(dir) do
      {:ok, names} -> names
      {:error, _} -> []
    end
  end

  defp look(guest, cwd, copy) do
    case guest.exec.(["sh", "-c", @look, "mdt-handoff", cwd, copy]) do
      {:ok, output} ->
        case String.split(output, "\n", parts: 5) do
          [top, common, real_copy, branch, dirty] ->
            cond do
              real_copy == "" or common != real_copy <> "/.git" -> {:error, :not_in_a_project}
              top == real_copy -> {:error, :not_a_worktree}
              branch == "" -> {:error, :detached}
              String.trim(dirty) != "" -> {:error, {:uncommitted, String.trim_trailing(dirty)}}
              not ref?(branch) -> {:error, :bad_branch}
              true -> {:ok, branch}
            end

          _ ->
            {:error, :not_in_a_project}
        end

      {:error, _} ->
        {:error, :not_in_a_project}
    end
  end

  # The branch's name comes from the VM and goes into a ref of yours.
  defp ref?(branch) do
    branch =~ ~r"\A[A-Za-z0-9][A-Za-z0-9._/-]{0,199}\z" and
      not String.contains?(branch, ["..", "//", "@{"]) and
      not String.ends_with?(branch, ["/", ".", ".lock"])
  end

  @doc "Why a handoff was not taken, in words for the agent."
  @spec explain(refusal() | String.t()) :: String.t()
  def explain(:no_title), do: "Give it a title: mdt handoff --title \"what this is\""

  def explain(:not_in_a_project),
    do: "This folder isn't in a project MDT knows. Run it in a worktree of one, under /work."

  def explain(:not_a_worktree),
    do:
      "This is the project's own folder, which follows the user's branch. Work in a worktree of your own: git worktree add ../NAME.wt/TASK -b TASK host/BRANCH"

  def explain(:detached), do: "This worktree is on no branch. Hand off a branch."

  def explain({:uncommitted, files}),
    do: "Commit or discard these first; a handoff is what you committed:\n" <> files

  def explain(:bad_branch),
    do: "MDT can't take a branch with that name. Use letters, digits, dots, dashes and slashes."

  def explain(:unrelated), do: "This branch shares no history with the user's repository."

  def explain(:too_large),
    do:
      "This handoff brings more than #{div(@size_limit_mib, 1024)} GiB of new data, which is more than MDT takes. Leave large generated files out of the commits."

  def explain(text) when is_binary(text), do: text

  @doc """
  What MDT works out about a handoff against your repository as it is now:
  its size, its commits' messages (claims), how far your branch has moved
  since it was built, and whether it merges with your working tree.
  """
  @spec facts(Project.t(), t()) :: facts()
  def facts(%Project{path: repo}, %__MODULE__{base: base, commit: commit}) do
    files =
      case HostGit.run(repo, ["diff", "--numstat", "--no-renames", "-z", base, commit]) do
        {:ok, output} ->
          for entry <- String.split(output, <<0>>, trim: true),
              [added, removed, path] <- [String.split(entry, "\t", parts: 3)] do
            %{path: path, added: count(added), removed: count(removed)}
          end

        {:error, _} ->
          []
      end

    messages =
      case HostGit.run(repo, ["log", "--format=%s", "--max-count=50", "#{base}..#{commit}"]) do
        {:ok, output} -> output |> String.split("\n", trim: true) |> Enum.map(&Shown.text/1)
        {:error, _} -> []
      end

    conflicts =
      with {:ok, snapshot} <- HostGit.snapshot(repo),
           {:ok, _tree, conflicts} <- merge(repo, snapshot, commit) do
        conflicts
      else
        _ -> []
      end

    # File names and commit messages are the VM's: they are matched as they
    # are, and leave here as text that shows all it holds.
    %{
      commits: number(repo, ["rev-list", "--count", "#{base}..#{commit}"]),
      messages: messages,
      files: Enum.map(files, &%{&1 | path: Shown.text(&1.path)}),
      added: files |> Enum.map(&(&1.added || 0)) |> Enum.sum(),
      removed: files |> Enum.map(&(&1.removed || 0)) |> Enum.sum(),
      behind: number(repo, ["rev-list", "--count", "#{commit}..HEAD"]),
      conflicts: Enum.map(conflicts, &Shown.text/1),
      hints: hints(files)
    }
  end

  defp hints(files) do
    for %{path: path} <- files,
        {pattern, why} <- @runs,
        path =~ pattern,
        uniq: true,
        do: "It changes #{Shown.text(path)}, #{why}."
  end

  @doc """
  The change as a diff against what it was built on, for reading: text that
  shows all it holds, and at most its first 512 KiB, with a last line that
  says so when there is more.
  """
  @spec diff(Project.t(), t()) :: {:ok, String.t()} | {:error, String.t()}
  def diff(%Project{path: repo}, %__MODULE__{base: base, commit: commit}) do
    case HostGit.run(repo, ["diff", "--no-color", "--no-ext-diff", base, commit],
           max: @diff_shown,
           cut: true
         ) do
      {:ok, diff} ->
        {:ok, Shown.text(diff)}

      {:cut, start} ->
        {:ok,
         Shown.text(start) <>
           "\n… the diff goes on. This is its first #{div(@diff_shown, 1024)} KiB; " <>
           "see all of it with: git diff #{short(base)} #{short(commit)}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp short(commit), do: String.slice(commit, 0, 10)

  @doc """
  Brings the whole handoff into your working tree, as uncommitted changes.

  Each file is the three-way merge of the handoff with what you have there
  now, your own uncommitted edits included. Your branch, your index and
  what you staged stay as they were, and no commit is made.

  When it doesn't merge, nothing is written and the files that conflict
  come back; with `anyway?` they are written with conflict markers. A new
  file where you already have one that git ignores is in the way, and
  nothing is written either.
  """
  @spec bring(Project.t(), t(), boolean()) ::
          {:ok, undo()} | {:error, {:conflicts | :in_the_way, [String.t()]} | String.t()}
  def bring(%Project{path: repo}, %__MODULE__{id: id, commit: commit}, anyway? \\ false) do
    with {:ok, snapshot} <- HostGit.snapshot(repo),
         {:ok, tree, conflicts} <- merge(repo, snapshot, commit),
         true <- conflicts == [] or anyway? or {:error, {:conflicts, conflicts}},
         {:ok, changes} <-
           HostGit.run(repo, ["diff", "--name-status", "--no-renames", "-z", snapshot, tree]),
         changes = changes |> String.split(<<0>>, trim: true) |> Enum.chunk_every(2),
         paths = for([_status, path] <- changes, do: path),
         created = for(["A", path] <- changes, do: path),
         # The snapshot holds every file of yours but the ignored ones.
         [] <- Enum.filter(created, &exists?(repo, &1)),
         # Kept alive for undo, where git's own cleanup can't reach it.
         {:ok, _} <- HostGit.run(repo, ["update-ref", "refs/mdt/undo/#{id}", snapshot]),
         :ok <- restore(repo, tree, paths) do
      {:ok, %{snapshot: snapshot, paths: paths, created: created}}
    else
      [_ | _] = in_the_way -> {:error, {:in_the_way, in_the_way}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Puts back what a bring changed: your working tree as it was before it."
  @spec undo(Project.t(), undo()) :: :ok | {:error, String.t()}
  def undo(%Project{path: repo}, %{snapshot: snapshot, paths: paths, created: created}) do
    with :ok <- restore(repo, snapshot, paths -- created) do
      for path <- created, plain?(repo, path) do
        File.rm(Path.join(repo, path))
        prune(repo, Path.dirname(path))
      end

      :ok
    end
  end

  @doc """
  Takes `vm/<branch>` away, as when a handoff stops waiting, unless a newer
  handoff of the same branch has moved it. Its commit stays reachable for
  MDT (`refs/mdt/handoffs/<id>`), so a bring can still be undone.
  """
  @spec hide(Project.t(), t()) :: :ok
  def hide(%Project{path: repo}, %__MODULE__{branch: branch, commit: commit}) do
    HostGit.run(repo, ["update-ref", "-d", "refs/remotes/vm/#{branch}", commit])
    :ok
  end

  @doc "Puts `vm/<branch>` back at the handoff's commit, as when it waits again."
  @spec show(Project.t(), t()) :: :ok
  def show(%Project{path: repo}, %__MODULE__{branch: branch, commit: commit}) do
    HostGit.run(repo, ["update-ref", "refs/remotes/vm/#{branch}", commit])
    :ok
  end

  @doc "Lets go of everything MDT kept of a handoff in your repository."
  @spec forget(Project.t(), t()) :: :ok
  def forget(%Project{path: repo}, %__MODULE__{id: id}) do
    HostGit.run(repo, ["update-ref", "-d", "refs/mdt/handoffs/#{id}"])
    HostGit.run(repo, ["update-ref", "-d", "refs/mdt/undo/#{id}"])
    :ok
  end

  # The merge of your working tree (as `ours`) with the handoff, computed
  # without touching anything: the tree it makes, and the files in it that
  # hold conflict markers.
  defp merge(repo, ours, theirs) do
    case HostGit.run(repo, ["merge-tree", "--write-tree", "--name-only", "-z", ours, theirs],
           ok: [0, 1]
         ) do
      {:ok, output} ->
        case String.split(output, <<0>>) do
          [tree | rest] when byte_size(tree) >= 40 ->
            {:ok, tree, rest |> Enum.take_while(&(&1 != "")) |> Enum.uniq()}

          _ ->
            {:error, "git could not merge it: " <> String.slice(output, 0, 300)}
        end

      {:error, message} ->
        {:error, message}
    end
  end

  # git writes the paths itself, from a tree, into the working tree only:
  # its own checks on paths and links apply, and the index is not touched.
  defp restore(_repo, _tree, []), do: :ok

  defp restore(repo, tree, paths) do
    list = Path.join(System.tmp_dir!(), "mdt-paths-#{System.unique_integer([:positive])}")
    File.write!(list, Enum.map(paths, &[&1, 0]))

    try do
      case HostGit.run(
             repo,
             [
               "restore",
               "--source=#{tree}",
               "--worktree",
               "--pathspec-from-file=#{list}",
               "--pathspec-file-nul"
             ],
             env: [{"GIT_LITERAL_PATHSPECS", "1"}]
           ) do
        {:ok, _} -> :ok
        {:error, message} -> {:error, message}
      end
    after
      File.rm(list)
    end
  end

  defp exists?(repo, path), do: match?({:ok, _}, File.lstat(Path.join(repo, path)))

  # Whether every folder on the way to `path` is a real folder of the
  # repository, so removing the file removes nothing elsewhere.
  defp plain?(repo, path) do
    path
    |> Path.split()
    |> Enum.drop(-1)
    |> Enum.reduce_while(repo, fn part, at ->
      next = Path.join(at, part)

      case File.lstat(next) do
        {:ok, %File.Stat{type: :directory}} -> {:cont, next}
        _ -> {:halt, nil}
      end
    end) != nil
  end

  # Removes folders a bring made that are empty again, up to the repository.
  defp prune(_repo, "."), do: :ok

  defp prune(repo, relative) do
    case File.rmdir(Path.join(repo, relative)) do
      :ok -> prune(repo, Path.dirname(relative))
      {:error, _not_empty_or_gone} -> :ok
    end
  end

  defp number(repo, args) do
    case HostGit.line(repo, args) do
      nil -> 0
      text -> String.to_integer(text)
    end
  end

  defp count("-"), do: nil
  defp count(text), do: String.to_integer(text)

  defp text(value) when is_binary(value), do: value
  defp text(_other), do: ""

  # The agent's words, for you to read.
  defp shown(value), do: value |> text() |> Shown.text()
end
