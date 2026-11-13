defmodule MDTClient.Sandbox.Landing do
  @moduledoc """
  Bringing a pull request into your repository, where and how you choose.

  **How:**

    * `:changes` - only the change, as uncommitted edits in a working tree,
      each file the three-way merge of the pull request with what is there
      now, your own uncommitted edits included. Nothing is committed or
      staged, and no branch moves. Undo puts the files back.
    * `:commits` - the agent's commits themselves, on a branch of yours:
      merged into the branch a worktree has checked out (a fast-forward
      when it can be), or as a new branch.

  **Where** (`t:where/0`):

    * `{:worktree, path}` - one of the repository's worktrees, as it is;
    * `{:new_worktree, path, branch}` - a new worktree on a new branch,
      started from the base branch (`:changes`) or at the pull request's
      commit (`:commits`);
    * `{:new_branch, branch}` - a new branch at the pull request's commit,
      checked out nowhere (`:commits` only).

  `preview/4` says what would happen, without writing anything into your
  repository. `land/4` does it: only then do the pull request's commits
  arrive in your repository, as `refs/mdt/pulls/<id>` while it runs.
  """

  alias MDTClient.Sandbox.{HostGit, PullRequest, PullStore, Shares, Shown}

  @type how :: :changes | :commits
  @type where ::
          {:worktree, Path.t()}
          | {:new_worktree, Path.t(), String.t()}
          | {:new_branch, String.t()}
  @type choice :: %{how: how(), where: where()}

  @type worktree :: %{
          path: Path.t(),
          branch: String.t() | nil,
          head: String.t() | nil,
          changes: non_neg_integer(),
          main?: boolean()
        }

  @type problem ::
          {:conflicts, [String.t()]}
          | {:in_the_way, [String.t()]}
          | {:branch_taken, String.t()}
          | {:bad_branch, String.t()}
          | {:path_taken, String.t()}
          | {:bad_path, String.t()}
          | {:path_writable, String.t()}
          | :not_a_worktree
          | :needs_a_worktree
          | :worktree_detached
          | :nothing_to_undo
          | :moved
          | String.t()

  @doc "The repository's worktrees: where each is, its branch, and how many files it has changed."
  @spec worktrees(Path.t()) :: [worktree()]
  def worktrees(repo) do
    case HostGit.run(repo, ["worktree", "list", "--porcelain", "-z"]) do
      {:ok, output} ->
        output
        |> String.split(<<0, 0>>, trim: true)
        |> Enum.map(&String.split(&1, <<0>>, trim: true))
        |> Enum.with_index()
        |> Enum.flat_map(fn {fields, index} -> worktree(fields, index == 0) end)

      {:error, _} ->
        []
    end
  end

  defp worktree(["worktree " <> path | fields], main?) do
    cond do
      "bare" in fields or Enum.any?(fields, &String.starts_with?(&1, "prunable")) ->
        []

      not File.dir?(path) ->
        []

      true ->
        head =
          Enum.find_value(fields, fn f -> with "HEAD " <> sha <- f, do: sha, else: (_ -> nil) end)

        branch =
          Enum.find_value(fields, fn f ->
            with "branch refs/heads/" <> name <- f, do: name, else: (_ -> nil)
          end)

        [%{path: path, branch: branch, head: head, changes: changes(path), main?: main?}]
    end
  end

  defp worktree(_fields, _main?), do: []

  defp changes(path) do
    case HostGit.run(path, ["status", "--porcelain", "-z", "--untracked-files=normal"]) do
      {:ok, output} -> output |> String.split(<<0>>, trim: true) |> length()
      {:error, _} -> 0
    end
  end

  @doc """
  A new worktree's folder, made from the branch's name: in `.worktrees/`
  inside the repository when it has that folder, else beside it.
  """
  @spec default_path(Path.t(), String.t()) :: Path.t()
  def default_path(repo, branch) do
    slug = branch |> String.replace(~r/[^A-Za-z0-9._-]+/, "-") |> String.trim("-")

    if File.dir?(Path.join(repo, ".worktrees")),
      do: Path.join([repo, ".worktrees", slug]),
      else: Path.join(Path.dirname(repo), "#{Path.basename(repo)}-#{slug}")
  end

  @doc "A branch name for the pull request that your repository doesn't have yet."
  @spec default_branch(Path.t(), PullRequest.t()) :: String.t()
  def default_branch(repo, %PullRequest{id: id, source: %{branch: branch}}) do
    taken = MapSet.new(PullRequest.branches(repo))

    Enum.find(
      [branch, "pr-#{id}-#{branch}", "pr-#{id}"],
      "pr-#{id}-#{System.unique_integer([:positive])}",
      &(not MapSet.member?(taken, &1))
    )
  end

  @doc """
  What bringing the pull request in this way would do, worked out without
  writing into your repository: `{:ok, %{conflicts: files, fast_forward?:
  bool}}`, or the problem that stops it before any merge.
  """
  @spec preview(Path.t(), PullRequest.t(), choice(), keyword()) ::
          {:ok, map()} | {:error, problem()}
  def preview(store, %PullRequest{repo: repo, head: head} = pull, choice, opts \\ []) do
    with :ok <- check(repo, choice, opts) do
      PullStore.view(store, fn env ->
        case {choice.how, choice.where} do
          {:changes, {:worktree, path}} ->
            with {:ok, snapshot} <- HostGit.snapshot(path, env) do
              {:ok, %{conflicts: shown(PullRequest.conflicts(store, snapshot, head, env))}}
            end

          {:commits, {:worktree, path}} ->
            ours = HostGit.line(path, ["rev-parse", "HEAD"])

            {:ok,
             %{
               conflicts: shown(PullRequest.conflicts(store, ours, head, env)),
               fast_forward?: ancestor?(store, ours, head, env),
               up_to_date?: ancestor?(store, head, ours, env)
             }}

          {:changes, {:new_worktree, _path, _branch}} ->
            tip = base_tip(pull)
            {:ok, %{conflicts: shown(PullRequest.conflicts(store, tip, head, env))}}

          {:commits, _new} ->
            {:ok, %{conflicts: []}}
        end
      end)
    end
  end

  defp shown(files), do: Enum.map(files, &Shown.text/1)

  defp ancestor?(repo, older, newer, env) do
    match?({:ok, _}, HostGit.run(repo, ["merge-base", "--is-ancestor", older, newer], env: env))
  end

  defp base_tip(%PullRequest{repo: repo, base: base}),
    do: HostGit.line(repo, ["rev-parse", "--verify", "--quiet", "refs/heads/#{base}^{commit}"])

  # What can be checked before any git work: the worktree is the
  # repository's, the new branch and folder are free.
  defp check(repo, %{how: how, where: where}, opts) do
    case where do
      {:worktree, path} ->
        case Enum.find(worktrees(repo), &(&1.path == path)) do
          nil -> {:error, :not_a_worktree}
          %{branch: nil} when how == :commits -> {:error, :worktree_detached}
          _ -> :ok
        end

      {:new_worktree, path, branch} ->
        with :ok <- new_branch(repo, branch), do: new_path(path, Keyword.get(opts, :shares, []))

      {:new_branch, _branch} when how == :changes ->
        {:error, :needs_a_worktree}

      {:new_branch, branch} ->
        new_branch(repo, branch)
    end
  end

  defp new_branch(repo, branch) do
    cond do
      not is_binary(branch) or branch == "" or
          not match?({:ok, _}, HostGit.run(repo, ["check-ref-format", "--branch", branch])) ->
        {:error, {:bad_branch, Shown.text(to_string(branch))}}

      HostGit.line(repo, ["rev-parse", "--verify", "--quiet", "refs/heads/#{branch}"]) ->
        {:error, {:branch_taken, branch}}

      true ->
        :ok
    end
  end

  defp new_path(path, shares) do
    expanded = path |> to_string() |> String.trim() |> Path.expand()

    cond do
      not String.starts_with?(String.trim(to_string(path)), ["/", "~/"]) ->
        {:error, {:bad_path, Shown.text(to_string(path))}}

      File.exists?(expanded) ->
        {:error, {:path_taken, expanded}}

      true ->
        {:ok, real} = Shares.realpath(expanded)

        case Enum.find(shares, &(&1.mode == :rw and Shares.within?(real, &1.path))) do
          nil -> :ok
          share -> {:error, {:path_writable, share.path}}
        end
    end
  end

  @doc """
  Brings the pull request in. With `anyway?`, `:changes` that conflict are
  written with conflict markers instead of refused. Returns what the record
  keeps (`t:MDTClient.Sandbox.PullRequest.landed/0`).
  """
  @spec land(Path.t(), PullRequest.t(), choice(), keyword()) ::
          {:ok, PullRequest.landed()} | {:error, problem()}
  def land(store, %PullRequest{repo: repo, id: id} = pull, choice, opts \\ []) do
    anyway? = Keyword.get(opts, :anyway, false)

    with :ok <- check(repo, choice, opts),
         {:ok, commit} <- PullStore.copy_into(store, repo, id) do
      result = place(pull, commit, choice, anyway?)
      HostGit.run(repo, ["update-ref", "-d", "refs/mdt/pulls/#{id}"])

      with {:ok, undo, branch, worktree} <- result do
        {:ok,
         %{
           how: choice.how,
           worktree: worktree,
           branch: branch,
           undo: undo,
           at: DateTime.utc_now() |> DateTime.truncate(:second)
         }}
      end
    end
  end

  defp place(pull, commit, %{how: :changes, where: {:worktree, path}}, anyway?) do
    branch = HostGit.branch(path)

    with {:ok, undo} <- bring(path, pull.id, commit, anyway?) do
      {:ok, Map.put(undo, :kind, :changes), branch, path}
    end
  end

  defp place(pull, commit, %{how: :commits, where: {:worktree, path}}, _anyway?) do
    before = HostGit.line(path, ["rev-parse", "HEAD"])
    branch = HostGit.branch(path)

    with {:ok, _tree, []} <- PullRequest.merge_tree(path, before, commit),
         {:ok, _} <-
           HostGit.run(path, ["merge", "--no-edit", "-m", message(pull), commit], seconds: 300) do
      after_ = HostGit.line(path, ["rev-parse", "HEAD"])
      {:ok, %{kind: :merge, before: before, after: after_}, branch, path}
    else
      {:ok, _tree, conflicts} -> {:error, {:conflicts, shown(conflicts)}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp place(pull, commit, %{how: how, where: {:new_worktree, path, branch}}, anyway?) do
    path = Path.expand(path)
    start = if how == :commits, do: commit, else: base_tip(pull)

    with :ok <- clean_for(pull.repo, how, start, commit, anyway?),
         {:ok, _} <-
           HostGit.run(pull.repo, ["worktree", "add", "-b", branch, path, start], seconds: 300) do
      undo = %{kind: :new_worktree, path: path, branch: branch, at: start}

      if how == :changes do
        case bring(path, pull.id, commit, anyway?) do
          {:ok, brought} -> {:ok, Map.put(undo, :brought, brought), branch, path}
          {:error, reason} -> {:error, reason}
        end
      else
        {:ok, undo, branch, path}
      end
    end
  end

  defp place(pull, commit, %{how: :commits, where: {:new_branch, branch}}, _anyway?) do
    case HostGit.run(pull.repo, ["branch", branch, commit]) do
      {:ok, _} -> {:ok, %{kind: :new_branch, branch: branch, at: commit}, branch, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  # A new worktree for `:changes` starts from the base: it must merge
  # there, unless conflict markers are wanted.
  defp clean_for(_repo, :commits, _start, _commit, _anyway?), do: :ok
  defp clean_for(_repo, :changes, _start, _commit, true), do: :ok

  defp clean_for(repo, :changes, start, commit, false) do
    case PullRequest.merge_tree(repo, start, commit) do
      {:ok, _tree, []} -> :ok
      {:ok, _tree, conflicts} -> {:error, {:conflicts, shown(conflicts)}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp message(%PullRequest{id: id, title: title}),
    do: "Merge pull request ##{id} from the VM\n\n#{title}"

  @doc """
  Brings `commit` into the working tree at `path`, whole, as uncommitted
  changes, merged with what is there now. Your branch, your index and what
  you staged stay as they were.

  When it doesn't merge, nothing is written and the files that conflict
  come back; with `anyway?` they are written with conflict markers. A new
  file where you already have one that git ignores is in the way, and
  nothing is written either.
  """
  @spec bring(Path.t(), pos_integer(), String.t(), boolean()) ::
          {:ok, map()} | {:error, problem()}
  def bring(path, id, commit, anyway?) do
    with {:ok, snapshot} <- HostGit.snapshot(path),
         {:ok, tree, conflicts} <- PullRequest.merge_tree(path, snapshot, commit),
         true <- conflicts == [] or anyway? or {:error, {:conflicts, shown(conflicts)}},
         {:ok, changes} <-
           HostGit.run(path, ["diff", "--name-status", "--no-renames", "-z", snapshot, tree]),
         changes = changes |> String.split(<<0>>, trim: true) |> Enum.chunk_every(2),
         paths = for([_status, file] <- changes, do: file),
         created = for(["A", file] <- changes, do: file),
         # The snapshot holds every file of yours but the ignored ones.
         [] <- Enum.filter(created, &exists?(path, &1)),
         # Kept alive for undo, where git's own cleanup can't reach it.
         {:ok, _} <- HostGit.run(path, ["update-ref", "refs/mdt/undo/#{id}", snapshot]),
         :ok <- restore(path, tree, paths) do
      {:ok, %{snapshot: snapshot, paths: paths, created: created, ref: "refs/mdt/undo/#{id}"}}
    else
      [_ | _] = in_the_way -> {:error, {:in_the_way, shown(in_the_way)}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Takes a landed pull request back out, as far as it can be done safely."
  @spec undo(Path.t(), PullRequest.landed()) :: :ok | {:error, problem()}
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

  def undo(repo, %{undo: %{kind: :new_worktree} = undo}) do
    with :ok <- if(undo[:brought], do: unbring(undo.path, undo.brought), else: :ok),
         {:ok, _} <- HostGit.run(repo, ["worktree", "remove", undo.path]) do
      if undo[:brought], do: HostGit.run(repo, ["update-ref", "-d", undo.brought.ref])
      delete_branch(repo, undo.branch, undo.at)
    end
  end

  def undo(repo, %{undo: %{kind: :new_branch} = undo}),
    do: delete_branch(repo, undo.branch, undo.at)

  def undo(_repo, _landed), do: {:error, :nothing_to_undo}

  # Deletes a branch only while it is where MDT made it.
  defp delete_branch(repo, branch, at) do
    case HostGit.run(repo, ["update-ref", "-d", "refs/heads/#{branch}", at]) do
      {:ok, _} -> :ok
      {:error, _} -> {:error, :moved}
    end
  end

  defp unbring(path, %{snapshot: snapshot, paths: paths, created: created}) do
    with :ok <- restore(path, snapshot, paths -- created) do
      for file <- created, plain?(path, file) do
        File.rm(Path.join(path, file))
        prune(path, Path.dirname(file))
      end

      :ok
    end
  end

  @doc """
  Sends your base branch, as committed, to the repository the pull request
  came from, as `host/<base>`, so the agent can merge it and resolve what
  conflicts there. Nothing else of yours goes.
  """
  @spec send_base(PullRequest.t(), MDTClient.Sandbox.Guest.t()) :: :ok | {:error, String.t()}
  def send_base(%PullRequest{repo: repo, base: base, source: %{folder: folder}}, guest) do
    case HostGit.run(
           repo,
           ["push", "--porcelain", "--no-verify", guest.git_url.(folder)] ++
             ["+refs/heads/#{base}:refs/remotes/host/#{base}"],
           env: guest.env,
           seconds: 600
         ) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
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

  @doc "What stopped a landing, in words for you."
  @spec explain(problem()) :: String.t()
  def explain({:conflicts, files}),
    do: "It doesn't merge there. Files that conflict: " <> Enum.join(files, ", ") <> "."

  def explain({:in_the_way, files}),
    do:
      "You have files of your own, ignored by git, where it adds new ones: " <>
        Enum.join(files, ", ") <> "."

  def explain({:branch_taken, branch}), do: "You already have a branch #{branch}."
  def explain({:bad_branch, branch}), do: "\"#{branch}\" can't be a branch name."
  def explain({:path_taken, path}), do: "#{path} exists already. Choose a new folder."
  def explain({:bad_path, path}), do: "\"#{path}\" isn't a full path. Start it with / or ~/."

  def explain({:path_writable, shared}),
    do: "That folder is in #{shared}, which the VM can write. Choose one outside it."

  def explain(:not_a_worktree), do: "That folder isn't a worktree of this repository any more."
  def explain(:needs_a_worktree), do: "Only the changes need a working tree to land in."

  def explain(:worktree_detached),
    do: "That worktree is on no branch, so commits have nowhere to go."

  def explain(:nothing_to_undo), do: "There is nothing to undo."

  def explain(:moved),
    do: "It has moved since it was brought in, so MDT leaves it to you."

  def explain(text) when is_binary(text), do: text
end
