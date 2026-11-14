defmodule MDTClient.Sandbox.Accept do
  @moduledoc """
  Accepting a handoff onto its target branch.

  The target branch must be checked out in a worktree of your repository,
  and that worktree must have no pending work: no uncommitted change to a
  file git tracks. Files git doesn't track don't count, unless the handoff
  adds one where you have one. A handoff never lands on top of work you
  haven't committed, so what you accept is exactly what you review, and
  undo puts the worktree back to clean.

  **How:**

    * `:commits` - the agent's commits, merged into the target branch: a
      fast-forward when it can be, else a merge commit. Refused when they
      conflict.
    * `:changes` - only the change, as uncommitted edits in that worktree,
      for you to commit. With conflicts it is refused, unless you ask for
      conflict markers.

  `save_branch/3` instead puts the handoff's commits on a new branch,
  checked out nowhere, to look at it with your own tools without accepting
  it.

  `preview/3` says what would happen without writing anything into your
  repository. Only `run/4` and `save_branch/3` bring the handoff's commits
  into it, as `refs/mdt/handoffs/<id>` while they run.
  """

  alias MDTClient.Sandbox.{Handoff, HandoffStore, HostGit, Shown}

  @type how :: :commits | :changes

  @type worktree :: %{path: Path.t(), branch: String.t() | nil, head: String.t() | nil}

  @type problem ::
          {:conflicts, [String.t()]}
          | {:in_the_way, [String.t()]}
          | {:not_checked_out, String.t()}
          | {:pending, String.t(), Path.t(), [String.t()]}
          | {:branch_taken, String.t()}
          | {:bad_branch, String.t()}
          | :up_to_date
          | :no_identity
          | :nothing_to_undo
          | :moved
          | String.t()

  @doc "The repository's worktrees, with the branch each has checked out."
  @spec worktrees(Path.t()) :: [worktree()]
  def worktrees(repo) do
    case HostGit.run(repo, ["worktree", "list", "--porcelain", "-z"]) do
      {:ok, output} ->
        output
        |> String.split(<<0, 0>>, trim: true)
        |> Enum.map(&String.split(&1, <<0>>, trim: true))
        |> Enum.flat_map(&worktree/1)

      {:error, _} ->
        []
    end
  end

  defp worktree(["worktree " <> path | fields]) do
    if "bare" in fields or Enum.any?(fields, &String.starts_with?(&1, "prunable")) or
         not File.dir?(path) do
      []
    else
      field = fn prefix ->
        Enum.find_value(
          fields,
          &if(String.starts_with?(&1, prefix), do: String.replace_prefix(&1, prefix, ""))
        )
      end

      [%{path: path, branch: field.("branch refs/heads/"), head: field.("HEAD ")}]
    end
  end

  defp worktree(_fields), do: []

  @doc """
  The worktree a handoff onto `onto` lands in: the one that has it checked
  out, with no pending work.
  """
  @spec place(Path.t(), String.t()) :: {:ok, Path.t()} | {:error, problem()}
  def place(repo, onto) do
    case Enum.find(worktrees(repo), &(&1.branch == onto)) do
      nil ->
        {:error, {:not_checked_out, onto}}

      %{path: path} ->
        case pending(path) do
          [] -> {:ok, path}
          files -> {:error, {:pending, onto, path, files}}
        end
    end
  end

  # Uncommitted changes to tracked files, by name: staged or not.
  defp pending(path) do
    case HostGit.run(path, ["status", "--porcelain", "-z", "--untracked-files=no"]) do
      {:ok, output} ->
        output
        |> String.split(<<0>>, trim: true)
        |> Enum.map(&(&1 |> String.slice(3..-1//1) |> Shown.text()))
        |> Enum.take(20)

      {:error, message} ->
        [message]
    end
  end

  @doc """
  What accepting the handoff this way would do, worked out without writing
  into your repository: where it lands, the files that conflict, and
  whether it is a fast-forward.
  """
  @spec preview(Path.t(), Handoff.t(), how()) :: {:ok, map()} | {:error, problem()}
  def preview(store, %Handoff{repo: repo, onto: onto, head: head}, how) do
    with {:ok, path} <- place(repo, onto) do
      HandoffStore.view(store, fn env ->
        ours = HostGit.line(path, ["rev-parse", "HEAD"])

        {:ok,
         %{
           worktree: path,
           how: how,
           conflicts: shown(Handoff.conflicts(store, ours, head, env)),
           fast_forward?: how == :commits and ancestor?(store, ours, head, env),
           up_to_date?: ancestor?(store, head, ours, env)
         }}
      end)
    end
  end

  defp shown(files), do: Enum.map(files, &Shown.text/1)

  defp ancestor?(repo, older, newer, env) do
    match?({:ok, _}, HostGit.run(repo, ["merge-base", "--is-ancestor", older, newer], env: env))
  end

  @doc """
  Accepts the handoff onto its target branch. With `anyway: true`,
  `:changes` that conflict are written with conflict markers instead of
  refused. Returns what the record keeps (`t:MDTClient.Sandbox.Handoff.accepted/0`).
  """
  @spec run(Path.t(), Handoff.t(), how(), keyword()) ::
          {:ok, Handoff.accepted()} | {:error, problem()}
  def run(store, %Handoff{repo: repo, id: id, onto: onto} = handoff, how, opts \\ []) do
    anyway? = Keyword.get(opts, :anyway, false)

    with {:ok, path} <- place(repo, onto),
         {:ok, commit} <- HandoffStore.copy_into(store, repo, id) do
      result =
        case how do
          :commits -> merge(path, handoff, commit)
          :changes -> bring(path, id, commit, anyway?)
        end

      HostGit.run(repo, ["update-ref", "-d", "refs/mdt/handoffs/#{id}"])

      with {:ok, undo} <- result do
        {:ok, %{how: how, worktree: path, branch: onto, undo: undo, at: now()}}
      end
    end
  end

  defp merge(path, handoff, commit) do
    before = HostGit.line(path, ["rev-parse", "HEAD"])

    with {:ok, _tree, []} <- Handoff.merge_tree(path, before, commit),
         false <- ancestor?(path, commit, before, []) && {:error, :up_to_date},
         {:ok, _} <-
           HostGit.run(path, ["merge", "--no-edit", "-m", message(handoff), commit], seconds: 300) do
      {:ok, %{kind: :merge, before: before, after: HostGit.line(path, ["rev-parse", "HEAD"])}}
    else
      {:ok, _tree, conflicts} ->
        {:error, {:conflicts, shown(conflicts)}}

      {:error, "Committer identity unknown" <> _} ->
        {:error, :no_identity}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp message(%Handoff{id: id, title: title}),
    do: "Merge handoff ##{id} from the VM\n\n#{title}"

  @doc """
  Puts the handoff's commits on `branch`, a new branch checked out nowhere,
  so you can look at it with your own tools. It doesn't accept it.
  """
  @spec save_branch(Path.t(), Handoff.t(), String.t()) :: {:ok, String.t()} | {:error, problem()}
  def save_branch(store, %Handoff{repo: repo, id: id}, branch) do
    branch = String.trim(to_string(branch))

    with :ok <- new_branch(repo, branch),
         {:ok, commit} <- HandoffStore.copy_into(store, repo, id) do
      result = HostGit.run(repo, ["branch", branch, commit])
      HostGit.run(repo, ["update-ref", "-d", "refs/mdt/handoffs/#{id}"])

      case result do
        {:ok, _} -> {:ok, branch}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp new_branch(repo, branch) do
    cond do
      branch == "" or
          not match?({:ok, _}, HostGit.run(repo, ["check-ref-format", "--branch", branch])) ->
        {:error, {:bad_branch, Shown.text(branch)}}

      HostGit.line(repo, ["rev-parse", "--verify", "--quiet", "refs/heads/#{branch}"]) ->
        {:error, {:branch_taken, branch}}

      true ->
        :ok
    end
  end

  @doc "A name for `save_branch/3` that your repository doesn't have yet."
  @spec default_branch(Handoff.t()) :: String.t()
  def default_branch(%Handoff{repo: repo, id: id, source: %{branch: branch}}) do
    taken =
      case HostGit.run(repo, ["for-each-ref", "--format=%(refname:short)", "refs/heads"]) do
        {:ok, output} -> output |> String.split("\n", trim: true) |> MapSet.new()
        {:error, _} -> MapSet.new()
      end

    Enum.find(
      ["handoff-#{id}-#{branch}", "handoff-#{id}"],
      "handoff-#{id}-#{System.unique_integer([:positive])}",
      &(not MapSet.member?(taken, &1))
    )
  end

  @doc """
  Brings `commit` into the working tree at `path`, whole, as uncommitted
  changes, merged with what is there. The branch and the index stay as
  they were.

  When it doesn't merge, nothing is written and the files that conflict
  come back; with `anyway?` they are written with conflict markers. A new
  file where you already have one that git ignores is in the way, and
  nothing is written either.
  """
  @spec bring(Path.t(), pos_integer(), String.t(), boolean()) ::
          {:ok, map()} | {:error, problem()}
  def bring(path, id, commit, anyway?) do
    with {:ok, snapshot} <- HostGit.snapshot(path),
         {:ok, tree, conflicts} <- Handoff.merge_tree(path, snapshot, commit),
         true <- conflicts == [] or anyway? or {:error, {:conflicts, shown(conflicts)}},
         {:ok, changes} <-
           HostGit.run(path, ["diff", "--name-status", "--no-renames", "-z", snapshot, tree]),
         changes = changes |> String.split(<<0>>, trim: true) |> Enum.chunk_every(2),
         paths = for([_status, file] <- changes, do: file),
         true <- paths != [] or {:error, :up_to_date},
         created = for(["A", file] <- changes, do: file),
         # The snapshot holds every file of yours but the ignored ones.
         [] <- Enum.filter(created, &exists?(path, &1)),
         # Kept alive for undo, where git's own cleanup can't reach it.
         {:ok, _} <- HostGit.run(path, ["update-ref", "refs/mdt/undo/#{id}", snapshot]),
         :ok <- restore(path, tree, paths) do
      {:ok,
       %{
         kind: :changes,
         snapshot: snapshot,
         paths: paths,
         created: created,
         ref: "refs/mdt/undo/#{id}"
       }}
    else
      [_ | _] = in_the_way -> {:error, {:in_the_way, shown(in_the_way)}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Takes an accepted handoff back out, while that can be done safely."
  @spec undo(Path.t(), Handoff.accepted()) :: :ok | {:error, problem()}
  def undo(repo, %{undo: %{kind: :changes} = undo, worktree: path}) do
    with :ok <- unbring(path, undo) do
      HostGit.run(repo, ["update-ref", "-d", undo.ref])
      :ok
    end
  end

  def undo(_repo, %{undo: %{kind: :merge, before: before, after: after_}, worktree: path}) do
    # Only while the branch is where the merge left it; `--keep` keeps your
    # uncommitted edits, and refuses when they touch what it moves.
    if HostGit.line(path, ["rev-parse", "HEAD"]) == after_ do
      case HostGit.run(path, ["reset", "--keep", before]) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :moved}
    end
  end

  def undo(_repo, _accepted), do: {:error, :nothing_to_undo}

  defp unbring(path, %{snapshot: snapshot, paths: paths, created: created}) do
    with :ok <- restore(path, snapshot, paths -- created) do
      for file <- created, plain?(path, file) do
        File.rm(Path.join(path, file))
        prune(path, Path.dirname(file))
      end

      :ok
    end
  end

  # git writes the paths itself, from a tree, into the working tree only:
  # its own checks on paths and links apply, and the index is not touched.
  defp restore(_path, _tree, []), do: :ok

  defp restore(path, tree, paths) do
    list = Path.join(System.tmp_dir!(), "mdt-paths-#{System.unique_integer([:positive])}")
    File.write!(list, Enum.map(paths, &[&1, 0]))

    try do
      case HostGit.run(
             path,
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

  defp exists?(path, file), do: match?({:ok, _}, File.lstat(Path.join(path, file)))

  # Whether every folder on the way to `file` is a real folder of the
  # worktree, so removing the file removes nothing elsewhere.
  defp plain?(path, file) do
    file
    |> Path.split()
    |> Enum.drop(-1)
    |> Enum.reduce_while(path, fn part, at ->
      next = Path.join(at, part)

      case File.lstat(next) do
        {:ok, %File.Stat{type: :directory}} -> {:cont, next}
        _ -> {:halt, nil}
      end
    end) != nil
  end

  # Removes folders a bring made that are empty again, up to the worktree.
  defp prune(_path, "."), do: :ok

  defp prune(path, relative) do
    case File.rmdir(Path.join(path, relative)) do
      :ok -> prune(path, Path.dirname(relative))
      {:error, _not_empty_or_gone} -> :ok
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  @doc "What stopped an accept, in words for you."
  @spec explain(problem()) :: String.t()
  def explain({:conflicts, files}),
    do: "It doesn't merge there. Files that conflict: " <> Enum.join(files, ", ") <> "."

  def explain({:in_the_way, files}),
    do:
      "You have files of your own, ignored by git, where it adds new ones: " <>
        Enum.join(files, ", ") <> "."

  def explain({:not_checked_out, onto}),
    do: "#{onto} isn't checked out in any worktree of yours. Check it out to accept onto it."

  def explain({:pending, onto, path, files}),
    do:
      "Your #{onto} at #{path} has work you haven't committed: " <>
        Enum.join(files, ", ") <> ". Commit or stash it first."

  def explain({:branch_taken, branch}), do: "You already have a branch #{branch}."
  def explain({:bad_branch, branch}), do: "\"#{branch}\" can't be a branch name."
  def explain(:up_to_date), do: "Your branch has all of it already."

  def explain(:no_identity),
    do:
      "A merge commit is yours, and git doesn't know who you are there: set user.name and user.email, or take only the changes."

  def explain(:nothing_to_undo), do: "There is nothing to undo."
  def explain(:moved), do: "It has moved since it was accepted, so MDT leaves it to you."
  def explain(text) when is_binary(text), do: text
end
