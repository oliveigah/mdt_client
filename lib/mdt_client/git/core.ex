defmodule MDTClient.Git.Core do
  @moduledoc """
  The UI-facing API for an opened Git repository.

  `open/2` creates an immutable repository handle suitable for one application
  tab. The handle owns no process and stores no global state, so several tabs
  can safely use different worktrees and SSH key pairs.

  Read functions return structs shaped for the branch panel, graph, and commit
  inspector. Mutations execute Git directly without a shell and return a small
  `CommandResult`; callers can then request a fresh `snapshot/2`. A failed
  merge, rebase, cherry-pick, or revert includes the in-progress operation in
  the returned `Error`, allowing the UI to present continue, skip, and abort
  actions.

  File status, diffs, staging, and working-tree edits intentionally sit outside
  this module's history and reference API.
  """

  alias MDTClient.Git.Branch
  alias MDTClient.Git.Command
  alias MDTClient.Git.CommandResult
  alias MDTClient.Git.Commit
  alias MDTClient.Git.Error
  alias MDTClient.Git.Files
  alias MDTClient.Git.Operation
  alias MDTClient.Git.Remote
  alias MDTClient.Git.Repository
  alias MDTClient.Git.SSHKey
  alias MDTClient.Git.Snapshot
  alias MDTClient.Git.Stash
  alias MDTClient.Git.Tag

  @default_graph_limit 500
  @maximum_graph_limit 5_000

  @commit_format Enum.join(
                   [
                     "%H",
                     "%P",
                     "%an",
                     "%ae",
                     "%aI",
                     "%cn",
                     "%ce",
                     "%cI",
                     "%s",
                     "%b",
                     "%G?",
                     "%GS"
                   ],
                   "%x00"
                 ) <> "%x00%x1e"

  @branch_format Enum.join(
                   [
                     "%(refname)",
                     "%(refname:short)",
                     "%(objectname)",
                     "%(HEAD)",
                     "%(upstream)",
                     "%(upstream:short)",
                     "%(upstream:track,nobracket)",
                     "%(symref)"
                   ],
                   "%00"
                 ) <> "%00%1e"

  @tag_format Enum.join(
                [
                  "%(refname)",
                  "%(refname:short)",
                  "%(objectname)",
                  "%(*objectname)",
                  "%(objecttype)"
                ],
                "%00"
              ) <> "%00%1e"

  @stash_format Enum.join(["%gd", "%H", "%gs", "%cI"], "%x00") <> "%x00%x1e"
  @fingerprint_ref_format "%(refname)%00%(objectname)%00%(upstream:track)%00"

  @type result(value) :: {:ok, value} | {:error, Error.t()}
  @type mutation_result :: result(CommandResult.t())

  @doc "Opens the worktree containing `path`."
  @spec open(Path.t(), keyword()) :: result(Repository.t())
  def open(path, opts \\ [])

  def open(path, opts) when is_binary(path) and is_list(opts) do
    expanded = Path.expand(path)

    with :ok <- ensure_directory(expanded),
         {:ok, "true"} <- open_value(expanded, ["rev-parse", "--is-inside-work-tree"]),
         {:ok, root} <- open_value(expanded, ["rev-parse", "--show-toplevel"]),
         {:ok, git_dir} <- open_value(expanded, ["rev-parse", "--absolute-git-dir"]),
         {:ok, common_dir} <- open_value(root, ["rev-parse", "--git-common-dir"]) do
      {:ok,
       %Repository{
         path: Path.expand(root),
         git_dir: Path.expand(git_dir),
         common_dir: Path.expand(common_dir, root),
         ssh_key: nil
       }}
    else
      {:ok, _not_worktree} ->
        {:error, Error.new(:invalid_repository, "The selected folder is not a Git worktree")}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  def open(_path, _opts),
    do: {:error, Error.new(:invalid_argument, "Repository path must be a string")}

  @doc """
  Clones `url` into `destination` and opens the result.

  The destination must not already hold anything: a clone that lands in a
  populated folder is a mistake this cannot undo. Pass `private_key` and
  `public_key`, or an `ssh_key`, to authenticate the same way an opened
  repository would.
  """
  @spec clone(String.t(), Path.t(), keyword()) :: result(Repository.t())
  def clone(url, destination, opts \\ []) do
    with {:ok, url} <- text_argument(url, "Repository URL"),
         {:ok, destination} <- clone_destination(destination),
         {:ok, ssh_key} <- clone_ssh_key(opts),
         :ok <- run_clone(destination, url, ssh_key) do
      open(destination)
    end
  end

  @doc "The folder name `git clone` would create for `url`."
  @spec clone_name(String.t()) :: String.t()
  def clone_name(url) when is_binary(url) do
    url
    |> String.trim()
    |> String.trim_trailing("/")
    |> String.split(~r{[/:]})
    |> List.last()
    |> Kernel.||("")
    |> String.replace_suffix(".git", "")
    |> String.replace(~r/[^A-Za-z0-9._-]/, "")
  end

  def clone_name(_url), do: ""

  @doc "Returns a copy of a repository handle using a validated SSH key pair."
  @spec with_ssh_keys(Repository.t(), Path.t(), Path.t()) :: result(Repository.t())
  def with_ssh_keys(%Repository{} = repository, private_key, public_key) do
    with {:ok, ssh_key} <- SSHKey.new(private_key, public_key) do
      {:ok, %{repository | ssh_key: ssh_key}}
    end
  end

  @doc "Returns a copy of a repository handle that inherits normal Git authentication."
  @spec without_ssh_keys(Repository.t()) :: {:ok, Repository.t()}
  def without_ssh_keys(%Repository{} = repository), do: {:ok, %{repository | ssh_key: nil}}

  @doc "Lists configured remotes and identifies HTTPS URLs that can be converted to SSH."
  @spec list_remotes(Repository.t()) :: result([Remote.t()])
  def list_remotes(%Repository{} = repository) do
    with {:ok, output} <- Command.run(repository, ["remote", "-v"]) do
      parse_remotes(output)
    end
  end

  @doc "Changes both fetch and push URLs for an existing remote."
  @spec set_remote_url(Repository.t(), String.t(), String.t()) :: mutation_result()
  def set_remote_url(%Repository{} = repository, remote, url) do
    with {:ok, remote} <- validate_remote(repository, remote),
         {:ok, url} <- text_argument(url, "Remote URL"),
         {:ok, result} <-
           run_mutation(repository, :set_remote_url, ["remote", "set-url", "--", remote, url]),
         :ok <- clear_remote_push_urls(repository, remote) do
      {:ok, result}
    end
  end

  @doc "Changes an HTTP(S) remote to its equivalent SSH URL."
  @spec use_ssh_remote(Repository.t(), String.t()) :: mutation_result()
  def use_ssh_remote(%Repository{} = repository, name) do
    with {:ok, remotes} <- list_remotes(repository),
         %Remote{ssh_url: ssh_url} when is_binary(ssh_url) <-
           Enum.find(remotes, &(&1.name == name)) do
      set_remote_url(repository, name, ssh_url)
    else
      nil ->
        {:error, Error.new(:invalid_argument, "Remote #{inspect(name)} does not exist")}

      %Remote{} ->
        {:error, Error.new(:invalid_argument, "Remote #{inspect(name)} is not using HTTP(S)")}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc "Loads the dynamic state used by the branch list and graph."
  @spec snapshot(Repository.t(), keyword()) :: result(Snapshot.t())
  def snapshot(%Repository{} = repository, opts \\ []) do
    with {:ok, limit} <- graph_limit(opts) do
      [head, current_branch, branches, tags, operation] =
        [
          fn -> head(repository) end,
          fn -> current_branch(repository) end,
          fn -> list_branches(repository) end,
          fn -> list_tags(repository) end,
          fn -> operation(repository) end
        ]
        |> Enum.map(&Task.async/1)
        |> Task.await_many(:infinity)

      build_snapshot(
        repository,
        limit,
        head,
        current_branch,
        branches,
        tags,
        operation
      )
    end
  end

  defp build_snapshot(
         repository,
         limit,
         head_result,
         current_branch_result,
         branches_result,
         tags_result,
         operation_result
       ) do
    with {:ok, head} <- head_result,
         {:ok, current_branch} <- current_branch_result,
         {:ok, branches} <- branches_result,
         {:ok, tags} <- tags_result,
         {:ok, commits} <- graph_with_refs(repository, branches, tags, head, limit),
         {:ok, operation} <- operation_result do
      {:ok,
       %Snapshot{
         repository: repository,
         head: head,
         current_branch: current_branch,
         detached?: not is_nil(head) and is_nil(current_branch),
         branches: branches,
         tags: tags,
         commits: commits,
         operation: operation
       }}
    end
  end

  @doc "Returns a compact token for cheap background change detection."
  @spec fingerprint(Repository.t()) :: result(binary())
  def fingerprint(%Repository{} = repository) do
    [changes, sources] =
      [
        fn -> Files.status(repository) end,
        fn -> fingerprint_sources(repository) end
      ]
      |> Enum.map(&Task.async/1)
      |> Task.await_many(:infinity)

    with {:ok, changes} <- changes,
         {:ok, sources} <- sources do
      {:ok, fingerprint(repository, changes, sources)}
    end
  end

  @doc false
  def fingerprint_sources(%Repository{} = repository) do
    [refs, config] =
      [
        fn ->
          Command.run(repository, [
            "for-each-ref",
            "refs/heads",
            "refs/remotes",
            "refs/tags",
            "refs/stash",
            "--format=#{@fingerprint_ref_format}"
          ])
        end,
        fn -> Command.run(repository, ["config", "--local", "--null", "--list"]) end
      ]
      |> Enum.map(&Task.async/1)
      |> Task.await_many(:infinity)

    with {:ok, refs} <- refs,
         {:ok, config} <- config do
      {:ok, {refs, config, git_state_markers(repository)}}
    end
  end

  @doc false
  def fingerprint(%Repository{} = repository, changes, {refs, config, markers}) do
    {
      changes,
      changed_file_signatures(repository, changes),
      refs,
      config,
      markers
    }
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
  end

  @doc "Lists tags, resolved to the commits they point at."
  @spec list_tags(Repository.t()) :: result([Tag.t()])
  def list_tags(%Repository{} = repository) do
    with {:ok, output} <-
           Command.run(repository, ["for-each-ref", "refs/tags", "--format=#{@tag_format}"]) do
      parse_tags(output)
    end
  end

  @doc "Lists local and remote branches with tracking information."
  @spec list_branches(Repository.t()) :: result([Branch.t()])
  def list_branches(%Repository{} = repository) do
    with {:ok, output} <-
           Command.run(repository, [
             "for-each-ref",
             "refs/heads",
             "refs/remotes",
             "--format=#{@branch_format}"
           ]) do
      parse_branches(output)
    end
  end

  @doc "Returns commits in topological order, ready for graph layout."
  @spec graph(Repository.t(), keyword()) :: result([Commit.t()])
  def graph(%Repository{} = repository, opts \\ []) do
    with {:ok, limit} <- graph_limit(opts),
         {:ok, branches} <- list_branches(repository),
         {:ok, tags} <- list_tags(repository),
         {:ok, head} <- head(repository) do
      graph_with_refs(repository, branches, tags, head, limit)
    end
  end

  @doc "Loads metadata for one commit-ish."
  @spec get_commit(Repository.t(), String.t()) :: result(Commit.t())
  def get_commit(%Repository{} = repository, revision) do
    with {:ok, commit_id} <- resolve_commit(repository, revision),
         {:ok, branches} <- list_branches(repository),
         {:ok, tags} <- list_tags(repository),
         {:ok, output} <-
           Command.run(repository, [
             "show",
             "--no-patch",
             "--format=#{@commit_format}",
             commit_id
           ]),
         {:ok, [commit]} <- parse_commits(output, labels_by_commit(branches, tags)) do
      {:ok, commit}
    else
      {:ok, commits} when is_list(commits) ->
        {:error,
         Error.new(
           :invalid_output,
           "Git returned #{length(commits)} commits when one was expected"
         )}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc "Resolves a revision to a full commit object ID."
  @spec resolve_commit(Repository.t(), String.t()) :: result(String.t())
  def resolve_commit(%Repository{} = repository, revision) do
    with {:ok, revision} <- text_argument(revision, "Revision"),
         {:ok, output} <-
           Command.run(repository, [
             "rev-parse",
             "--verify",
             "--end-of-options",
             "#{revision}^{commit}"
           ]) do
      commit_id = output_line(output)

      if Regex.match?(~r/\A[0-9a-fA-F]{40,64}\z/, commit_id) do
        {:ok, String.downcase(commit_id)}
      else
        {:error, Error.new(:invalid_output, "Git returned an invalid commit object ID")}
      end
    end
  end

  @doc "Returns the operation currently in progress, if any."
  @spec operation(Repository.t()) :: result(Operation.t() | nil)
  def operation(%Repository{} = repository) do
    git_dir = repository.git_dir

    operation =
      cond do
        File.dir?(Path.join(git_dir, "rebase-merge")) ->
          rebase_operation(repository, Path.join(git_dir, "rebase-merge"), "msgnum", "end")

        File.dir?(Path.join(git_dir, "rebase-apply")) ->
          rebase_operation(repository, Path.join(git_dir, "rebase-apply"), "next", "last")

        File.exists?(Path.join(git_dir, "CHERRY_PICK_HEAD")) ->
          marker_operation(repository, :cherry_pick, "CHERRY_PICK_HEAD")

        File.exists?(Path.join(git_dir, "REVERT_HEAD")) ->
          marker_operation(repository, :revert, "REVERT_HEAD")

        File.exists?(Path.join(git_dir, "MERGE_HEAD")) ->
          marker_operation(repository, :merge, "MERGE_HEAD")

        File.exists?(Path.join(git_dir, "BISECT_LOG")) ->
          %Operation{kind: :bisect, original_head: read_optional(Path.join(git_dir, "ORIG_HEAD"))}

        true ->
          nil
      end

    {:ok, operation}
  end

  @doc "Creates a local branch at `start_point` without checking it out."
  @spec create_branch(Repository.t(), String.t(), String.t()) :: mutation_result()
  def create_branch(%Repository{} = repository, name, start_point \\ "HEAD") do
    with {:ok, name} <- validate_branch_name(repository, name),
         {:ok, start_point} <- resolve_commit(repository, start_point) do
      run_mutation(repository, :create_branch, ["branch", name, start_point])
    end
  end

  @doc "Checks out an existing local branch."
  @spec checkout_branch(Repository.t(), String.t()) :: mutation_result()
  def checkout_branch(%Repository{} = repository, name) do
    with {:ok, branch} <- find_branch(repository, name, :local) do
      run_mutation(repository, :checkout_branch, ["switch", "--", branch.name])
    end
  end

  @doc "Creates a local tracking branch from a remote branch and checks it out."
  @spec checkout_remote_branch(Repository.t(), String.t(), keyword()) :: mutation_result()
  def checkout_remote_branch(%Repository{} = repository, remote_branch, opts \\ []) do
    with {:ok, branch} <- find_branch(repository, remote_branch, :remote),
         {:ok, local_name} <-
           validate_branch_name(
             repository,
             Keyword.get(opts, :as, local_name_for_remote(branch))
           ) do
      run_mutation(repository, :checkout_remote_branch, [
        "switch",
        "--track",
        "-c",
        local_name,
        "--",
        branch.name
      ])
    end
  end

  @doc "Checks out a commit in detached HEAD mode."
  @spec checkout_commit(Repository.t(), String.t()) :: mutation_result()
  def checkout_commit(%Repository{} = repository, revision) do
    with {:ok, commit_id} <- resolve_commit(repository, revision) do
      run_mutation(repository, :checkout_commit, ["switch", "--detach", commit_id])
    end
  end

  @doc "Renames a local branch."
  @spec rename_branch(Repository.t(), String.t(), String.t(), keyword()) :: mutation_result()
  def rename_branch(%Repository{} = repository, old_name, new_name, opts \\ []) do
    with {:ok, old_branch} <- find_branch(repository, old_name, :local),
         {:ok, new_name} <- validate_branch_name(repository, new_name),
         {:ok, force?} <- boolean_option(opts, :force, false) do
      flag = if(force?, do: "-M", else: "-m")
      run_mutation(repository, :rename_branch, ["branch", flag, "--", old_branch.name, new_name])
    end
  end

  @doc "Deletes a local branch. Pass `force: true` for an unmerged branch."
  @spec delete_branch(Repository.t(), String.t(), keyword()) :: mutation_result()
  def delete_branch(%Repository{} = repository, name, opts \\ []) do
    with {:ok, branch} <- find_branch(repository, name, :local),
         {:ok, force?} <- boolean_option(opts, :force, false) do
      flag = if(force?, do: "-D", else: "-d")
      run_mutation(repository, :delete_branch, ["branch", flag, "--", branch.name])
    end
  end

  @doc "Creates a commit from the current index."
  @spec commit(Repository.t(), String.t(), keyword()) :: mutation_result()
  def commit(%Repository{} = repository, message, opts \\ []) do
    with {:ok, message} <- commit_message(message),
         {:ok, amend?} <- boolean_option(opts, :amend, false),
         {:ok, allow_empty?} <- boolean_option(opts, :allow_empty, false),
         {:ok, signing_args} <- signing_args(Keyword.get(opts, :sign, false)) do
      args =
        ["commit"] ++
          if_args(amend?, "--amend") ++
          if_args(allow_empty?, "--allow-empty") ++ signing_args ++ ["-m", message]

      run_mutation(repository, :commit, args)
    end
  end

  @doc "Stages the selected repository files, including deletions."
  @spec stage(Repository.t(), [Path.t()]) :: mutation_result()
  def stage(%Repository{} = repository, paths) do
    with {:ok, pathspecs} <- selected_pathspecs(repository, paths) do
      run_mutation(repository, :stage, ["add", "--" | pathspecs])
    end
  end

  @doc "Removes the selected files from the index while preserving working-tree changes."
  @spec unstage(Repository.t(), [Path.t()]) :: mutation_result()
  def unstage(%Repository{} = repository, paths) do
    with {:ok, pathspecs} <- selected_pathspecs(repository, paths),
         {:ok, head} <- head(repository) do
      args =
        if is_nil(head) do
          ["rm", "--cached", "--force", "--ignore-unmatch", "--" | pathspecs]
        else
          ["restore", "--staged", "--" | pathspecs]
        end

      run_mutation(repository, :unstage, args)
    end
  end

  @doc "Stashes changes belonging to the selected repository files."
  @spec stash(Repository.t(), [Path.t()], keyword()) :: mutation_result()
  def stash(%Repository{} = repository, paths, opts \\ []) do
    with {:ok, pathspecs} <- selected_pathspecs(repository, paths),
         {:ok, include_untracked?} <- boolean_option(opts, :include_untracked, true),
         {:ok, keep_index?} <- boolean_option(opts, :keep_index, false),
         {:ok, message_args} <- stash_message_args(Keyword.get(opts, :message)) do
      args =
        ["stash", "push"] ++
          if_args(include_untracked?, "--include-untracked") ++
          if_args(keep_index?, "--keep-index") ++ message_args ++ ["--" | pathspecs]

      run_mutation(repository, :stash, args)
    end
  end

  @doc "Lists stash entries, newest first."
  @spec list_stashes(Repository.t()) :: result([Stash.t()])
  def list_stashes(%Repository{} = repository) do
    with {:ok, output} <-
           Command.run(repository, ["stash", "list", "--format=#{@stash_format}"]) do
      parse_stashes(output)
    end
  end

  @doc "Applies a stash without removing it from the stash list."
  @spec apply_stash(Repository.t(), String.t(), keyword()) :: mutation_result()
  def apply_stash(%Repository{} = repository, reference \\ "stash@{0}", opts \\ []) do
    with {:ok, stash} <- find_stash(repository, reference),
         {:ok, reinstate_index?} <- boolean_option(opts, :reinstate_index, false) do
      args = ["stash", "apply"] ++ if_args(reinstate_index?, "--index") ++ [stash.reference]
      run_mutation(repository, :apply_stash, args)
    end
  end

  @doc "Applies a stash and removes it when application succeeds."
  @spec pop_stash(Repository.t(), String.t(), keyword()) :: mutation_result()
  def pop_stash(%Repository{} = repository, reference \\ "stash@{0}", opts \\ []) do
    with {:ok, stash} <- find_stash(repository, reference),
         {:ok, reinstate_index?} <- boolean_option(opts, :reinstate_index, false) do
      args = ["stash", "pop"] ++ if_args(reinstate_index?, "--index") ++ [stash.reference]
      run_mutation(repository, :pop_stash, args)
    end
  end

  @doc "Removes a stash without applying it."
  @spec drop_stash(Repository.t(), String.t()) :: mutation_result()
  def drop_stash(%Repository{} = repository, reference \\ "stash@{0}") do
    with {:ok, stash} <- find_stash(repository, reference) do
      run_mutation(repository, :drop_stash, ["stash", "drop", stash.reference])
    end
  end

  @doc "Merges a commit-ish into the checked-out branch."
  @spec merge(Repository.t(), String.t(), keyword()) :: mutation_result()
  def merge(%Repository{} = repository, revision, opts \\ []) do
    with {:ok, commit_id} <- resolve_commit(repository, revision),
         {:ok, no_ff?} <- boolean_option(opts, :no_ff, false),
         {:ok, squash?} <- boolean_option(opts, :squash, false),
         {:ok, message_args} <- optional_message_args(Keyword.get(opts, :message)) do
      args =
        ["merge"] ++
          if_args(no_ff?, "--no-ff") ++
          if_args(squash?, "--squash") ++ message_args ++ ["--", commit_id]

      run_mutation(repository, :merge, args)
    end
  end

  @doc "Rebases the checked-out branch onto a commit-ish."
  @spec rebase(Repository.t(), String.t(), keyword()) :: mutation_result()
  def rebase(%Repository{} = repository, onto, opts \\ []) do
    with {:ok, commit_id} <- resolve_commit(repository, onto),
         {:ok, rebase_merges?} <- boolean_option(opts, :rebase_merges, false),
         {:ok, autosquash?} <- boolean_option(opts, :autosquash, false) do
      args =
        ["rebase"] ++
          if_args(rebase_merges?, "--rebase-merges") ++
          if_args(autosquash?, "--autosquash") ++ [commit_id]

      run_mutation(repository, :rebase, args)
    end
  end

  @doc "Cherry-picks one commit or a list of commits in the given order."
  @spec cherry_pick(Repository.t(), String.t() | [String.t()], keyword()) :: mutation_result()
  def cherry_pick(%Repository{} = repository, revisions, opts \\ []) do
    with {:ok, revisions} <- revision_list(revisions),
         {:ok, commits} <- resolve_commits(repository, revisions),
         {:ok, no_commit?} <- boolean_option(opts, :no_commit, false) do
      args = ["cherry-pick"] ++ if_args(no_commit?, "--no-commit") ++ commits
      run_mutation(repository, :cherry_pick, args)
    end
  end

  @doc "Reverts one commit or a list of commits in the given order."
  @spec revert(Repository.t(), String.t() | [String.t()], keyword()) :: mutation_result()
  def revert(%Repository{} = repository, revisions, opts \\ []) do
    with {:ok, revisions} <- revision_list(revisions),
         {:ok, commits} <- resolve_commits(repository, revisions),
         {:ok, no_commit?} <- boolean_option(opts, :no_commit, false),
         {:ok, mainline_args} <- mainline_args(Keyword.get(opts, :mainline)) do
      args =
        ["revert", "--no-edit"] ++
          if_args(no_commit?, "--no-commit") ++ mainline_args ++ commits

      run_mutation(repository, :revert, args)
    end
  end

  @doc "Moves the checked-out branch with either soft or hard reset semantics."
  @spec reset(Repository.t(), String.t(), :soft | :hard) :: mutation_result()
  def reset(%Repository{} = repository, revision, mode) when mode in [:soft, :hard] do
    with {:ok, commit_id} <- resolve_commit(repository, revision) do
      run_mutation(repository, :reset, ["reset", "--#{mode}", commit_id])
    end
  end

  def reset(%Repository{}, _revision, _mode),
    do: {:error, Error.new(:invalid_argument, "Reset mode must be :soft or :hard")}

  @doc "Edits a commit message on the checked-out branch, rewriting descendants when needed."
  @spec edit_commit_message(Repository.t(), String.t(), String.t()) :: mutation_result()
  def edit_commit_message(%Repository{} = repository, revision, message) do
    with {:ok, target} <- resolve_commit(repository, revision),
         {:ok, current_head} <- require_head(repository),
         {:ok, message} <- commit_message(message) do
      if target == current_head do
        run_mutation(repository, :edit_commit_message, [
          "commit",
          "--amend",
          "--only",
          "-m",
          message
        ])
      else
        rewrite_commit_message(repository, target, current_head, message)
      end
    end
  end

  @doc "Fetches and prunes either every remote or one named remote."
  @spec fetch(Repository.t(), String.t() | nil) :: mutation_result()
  def fetch(repository, remote \\ nil)

  def fetch(%Repository{} = repository, nil) do
    run_mutation(repository, :fetch, ["fetch", "--all", "--prune"])
  end

  def fetch(%Repository{} = repository, remote) do
    with {:ok, remote} <- validate_remote(repository, remote) do
      run_mutation(repository, :fetch, ["fetch", "--prune", "--", remote])
    end
  end

  @doc "Pulls the current branch with an explicit integration strategy."
  @spec pull(Repository.t(), :ff_only | :rebase | :merge) :: mutation_result()
  def pull(repository, strategy \\ :ff_only)

  def pull(%Repository{} = repository, strategy) when strategy in [:ff_only, :rebase, :merge] do
    strategy_args =
      case strategy do
        :ff_only -> ["--ff-only"]
        :rebase -> ["--rebase"]
        :merge -> ["--no-rebase"]
      end

    run_mutation(repository, :pull, ["pull" | strategy_args])
  end

  def pull(%Repository{}, _strategy),
    do: {:error, Error.new(:invalid_argument, "Unknown pull strategy")}

  @doc "Pushes the current branch, or a named local branch, to a remote."
  @spec push(Repository.t(), keyword()) :: mutation_result()
  def push(%Repository{} = repository, opts \\ []) do
    with {:ok, force?} <- boolean_option(opts, :force_with_lease, false),
         {:ok, upstream?} <- boolean_option(opts, :set_upstream, false),
         {:ok, remote_args} <- push_remote_args(repository, Keyword.get(opts, :remote)),
         {:ok, branch_args} <- push_branch_args(repository, Keyword.get(opts, :branch)) do
      args =
        ["push"] ++
          if_args(force?, "--force-with-lease") ++
          if_args(upstream?, "--set-upstream") ++ remote_args ++ branch_args

      run_mutation(repository, :push, args)
    end
  end

  @doc "Deletes a branch from a named remote."
  @spec delete_remote_branch(Repository.t(), String.t(), String.t()) :: mutation_result()
  def delete_remote_branch(%Repository{} = repository, remote, branch) do
    with {:ok, remote} <- validate_remote(repository, remote),
         {:ok, branch} <- validate_branch_name(repository, branch) do
      run_mutation(repository, :delete_remote_branch, [
        "push",
        "--delete",
        "--repo=#{remote}",
        branch
      ])
    end
  end

  @doc "Continues the merge or history operation in progress."
  @spec continue_operation(Repository.t()) :: mutation_result()
  def continue_operation(%Repository{} = repository) do
    with {:ok, operation} <- require_operation(repository),
         {:ok, args} <- continuation_args(operation.kind) do
      run_mutation(repository, :continue_operation, args)
    end
  end

  @doc "Skips the current rebase, cherry-pick, or revert step."
  @spec skip_operation(Repository.t()) :: mutation_result()
  def skip_operation(%Repository{} = repository) do
    with {:ok, operation} <- require_operation(repository),
         {:ok, args} <- skip_args(operation.kind) do
      run_mutation(repository, :skip_operation, args)
    end
  end

  @doc "Aborts the merge or history operation in progress."
  @spec abort_operation(Repository.t()) :: mutation_result()
  def abort_operation(%Repository{} = repository) do
    with {:ok, operation} <- require_operation(repository),
         {:ok, args} <- abort_args(operation.kind) do
      run_mutation(repository, :abort_operation, args)
    end
  end

  defp clone_destination(destination) when is_binary(destination) do
    with {:ok, destination} <- text_argument(destination, "Destination folder") do
      expanded = Path.expand(destination)

      cond do
        File.regular?(expanded) ->
          {:error, Error.new(:invalid_argument, "The destination is a file")}

        File.dir?(expanded) and File.ls!(expanded) != [] ->
          {:error, Error.new(:invalid_argument, "The destination folder is not empty")}

        true ->
          {:ok, expanded}
      end
    end
  end

  defp clone_destination(_destination),
    do: {:error, Error.new(:invalid_argument, "Destination folder must be a string")}

  defp clone_ssh_key(opts) do
    case {Keyword.get(opts, :ssh_key), Keyword.get(opts, :private_key),
          Keyword.get(opts, :public_key)} do
      {%SSHKey{} = ssh_key, _private, _public} -> {:ok, ssh_key}
      {nil, nil, nil} -> {:ok, nil}
      {nil, private, public} -> SSHKey.new(private, public)
    end
  end

  defp run_clone(destination, url, ssh_key) do
    parent = Path.dirname(destination)
    args = ["clone", "--", url, destination]

    with :ok <- ensure_writable(parent) do
      case Command.capture_path(parent, args, ssh_key: ssh_key) do
        {:system_error, error} -> {:error, error}
        {_output, 0} -> :ok
        {output, status} -> {:error, Error.command(args, status, output)}
      end
    end
  end

  defp ensure_writable(path) do
    case File.mkdir_p(path) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error,
         Error.new(
           :invalid_argument,
           "Could not create #{path}: #{:file.format_error(reason)}"
         )}
    end
  end

  defp ensure_directory(path) do
    if File.dir?(path) do
      :ok
    else
      {:error, Error.new(:invalid_repository, "The selected repository folder does not exist")}
    end
  end

  defp open_value(path, args) do
    case Command.capture_path(path, args) do
      {:system_error, error} -> {:error, error}
      {output, 0} -> {:ok, output_line(output)}
      {output, _status} -> {:error, invalid_repository_error(output)}
    end
  end

  defp invalid_repository_error(output) do
    message =
      case String.trim(output) do
        "" -> "The selected folder is not a Git worktree"
        message -> message
      end

    Error.new(:invalid_repository, message)
  end

  defp graph_limit(opts) do
    case Keyword.get(opts, :limit, @default_graph_limit) do
      limit when is_integer(limit) and limit > 0 and limit <= @maximum_graph_limit ->
        {:ok, limit}

      _invalid ->
        {:error,
         Error.new(
           :invalid_argument,
           "Graph limit must be between 1 and #{@maximum_graph_limit}"
         )}
    end
  end

  defp head(repository) do
    case Command.capture(repository, ["rev-parse", "--verify", "HEAD"]) do
      {:system_error, error} -> {:error, error}
      {output, 0} -> {:ok, output_line(output)}
      {_output, _status} -> {:ok, nil}
    end
  end

  defp require_head(repository) do
    case head(repository) do
      {:ok, nil} -> {:error, Error.new(:invalid_argument, "The repository has no commits")}
      result -> result
    end
  end

  defp current_branch(repository) do
    case Command.capture(repository, ["symbolic-ref", "--quiet", "--short", "HEAD"]) do
      {:system_error, error} -> {:error, error}
      {output, 0} -> {:ok, output_line(output)}
      {_output, _status} -> {:ok, nil}
    end
  end

  defp graph_with_refs(repository, branches, tags, head, limit) do
    revisions = ["--all"] ++ if(is_nil(head), do: [], else: [head])

    with {:ok, output} <-
           Command.run(
             repository,
             [
               "log",
               "--topo-order",
               "--max-count=#{limit}",
               "--format=#{@commit_format}"
             ] ++ revisions
           ) do
      parse_commits(output, labels_by_commit(branches, tags))
    end
  end

  defp parse_branches(output) do
    output
    |> records()
    |> Enum.reduce_while({:ok, []}, fn record, {:ok, branches} ->
      case String.split(record, <<0>>, trim: false) do
        [full_name, name, target, current, _upstream_full, upstream, track, symbolic, ""] ->
          kind = if String.starts_with?(full_name, "refs/heads/"), do: :local, else: :remote

          branch = %Branch{
            name: name,
            full_name: full_name,
            kind: kind,
            target: target,
            current?: current == "*",
            upstream: blank_to_nil(upstream),
            remote: remote_name(kind, name),
            symbolic_target: blank_to_nil(symbolic),
            ahead: tracking_count(track, "ahead"),
            behind: tracking_count(track, "behind")
          }

          {:cont, {:ok, [branch | branches]}}

        _invalid ->
          {:halt, {:error, Error.new(:invalid_output, "Git returned invalid branch data")}}
      end
    end)
    |> case do
      {:ok, branches} ->
        {:ok,
         Enum.sort_by(branches, fn branch ->
           {if(branch.kind == :local, do: 0, else: 1), String.downcase(branch.name)}
         end)}

      error ->
        error
    end
  end

  defp parse_remotes(output) do
    output
    |> lines()
    |> Enum.reduce_while({:ok, %{}}, fn line, {:ok, remotes} ->
      case Regex.run(~r/\A([^\t]+)\t(.*) \((fetch|push)\)\z/, line, capture: :all_but_first) do
        [name, url, direction] ->
          urls = Map.get(remotes, name, %{}) |> Map.put(direction, url)
          {:cont, {:ok, Map.put(remotes, name, urls)}}

        _invalid ->
          {:halt, {:error, Error.new(:invalid_output, "Git returned invalid remote data")}}
      end
    end)
    |> case do
      {:ok, remotes} ->
        remotes =
          remotes
          |> Enum.map(fn {name, urls} ->
            fetch_url = Map.get(urls, "fetch") || Map.fetch!(urls, "push")
            push_url = Map.get(urls, "push") || fetch_url

            %Remote{
              name: name,
              fetch_url: fetch_url,
              push_url: push_url,
              kind: remote_kind(push_url),
              ssh_url: ssh_url(push_url)
            }
          end)
          |> Enum.sort_by(&String.downcase(&1.name))

        {:ok, remotes}

      error ->
        error
    end
  end

  defp changed_file_signatures(repository, changes) do
    Enum.map(changes, fn change ->
      {change.path, file_signature(Path.join(repository.path, change.path))}
    end)
  end

  defp git_state_markers(repository) do
    marker_contents =
      for name <- [
            "HEAD",
            "MERGE_HEAD",
            "CHERRY_PICK_HEAD",
            "REVERT_HEAD",
            "BISECT_LOG",
            "rebase-merge/msgnum",
            "rebase-merge/end",
            "rebase-apply/next",
            "rebase-apply/last"
          ] do
        path = Path.join(repository.git_dir, name)
        {name, File.read(path)}
      end

    marker_contents
  end

  defp file_signature(path) do
    case File.stat(path, time: :posix) do
      {:ok, stat} ->
        {stat.type, stat.size, stat.mtime, stat.ctime, stat.inode, stat.mode}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp remote_kind(url) do
    cond do
      String.starts_with?(url, ["git@", "ssh://"]) -> :ssh
      String.starts_with?(url, "https://") -> :https
      String.starts_with?(url, "http://") -> :http
      String.starts_with?(url, ["file://", "/", "./", "../"]) -> :file
      true -> :other
    end
  end

  defp ssh_url(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host, path: path}
      when scheme in ["http", "https"] and is_binary(host) and is_binary(path) ->
        repository_path = String.trim_leading(path, "/")

        if repository_path == "" do
          nil
        else
          "git@#{host}:#{repository_path}"
        end

      _other ->
        nil
    end
  end

  defp parse_commits(output, labels) do
    output
    |> records()
    |> Enum.reduce_while({:ok, []}, fn record, {:ok, commits} ->
      case parse_commit(record, labels) do
        {:ok, commit} -> {:cont, {:ok, [commit | commits]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, commits} -> {:ok, Enum.reverse(commits)}
      error -> error
    end
  end

  defp parse_stashes(output) do
    output
    |> records()
    |> Enum.reduce_while({:ok, []}, fn record, {:ok, stashes} ->
      case String.split(record, <<0>>, trim: false) do
        [reference, commit, summary, created_at, ""] ->
          with {:ok, index} <- stash_index(reference),
               {:ok, created_at} <- parse_datetime(created_at) do
            stash = %Stash{
              index: index,
              reference: reference,
              commit: commit,
              summary: summary,
              created_at: created_at
            }

            {:cont, {:ok, [stash | stashes]}}
          else
            {:error, error} -> {:halt, {:error, error}}
          end

        _invalid ->
          {:halt, {:error, Error.new(:invalid_output, "Git returned invalid stash data")}}
      end
    end)
    |> case do
      {:ok, stashes} -> {:ok, Enum.reverse(stashes)}
      error -> error
    end
  end

  defp stash_index(reference) do
    case Regex.run(~r/\Astash@\{(\d+)\}\z/, reference, capture: :all_but_first) do
      [index] -> {:ok, String.to_integer(index)}
      _invalid -> {:error, Error.new(:invalid_output, "Git returned an invalid stash reference")}
    end
  end

  defp parse_commit(record, labels) do
    case String.split(record, <<0>>, trim: false) do
      [
        id,
        parents,
        author_name,
        author_email,
        authored_at,
        committer_name,
        committer_email,
        committed_at,
        summary,
        body,
        signature_status,
        signature_signer,
        ""
      ] ->
        with {:ok, authored_at} <- parse_datetime(authored_at),
             {:ok, committed_at} <- parse_datetime(committed_at) do
          {:ok,
           %Commit{
             id: id,
             parents: words(parents),
             author_name: author_name,
             author_email: author_email,
             authored_at: authored_at,
             committer_name: committer_name,
             committer_email: committer_email,
             committed_at: committed_at,
             summary: summary,
             body: String.trim_trailing(body, "\n"),
             signature_status: signature_status(signature_status),
             signature_signer: blank_to_nil(signature_signer),
             labels: Map.get(labels, id, [])
           }}
        end

      _invalid ->
        {:error, Error.new(:invalid_output, "Git returned invalid commit data")}
    end
  end

  defp parse_datetime(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      _invalid -> {:error, Error.new(:invalid_output, "Git returned an invalid commit date")}
    end
  end

  defp signature_status("G"), do: :good
  defp signature_status("B"), do: :bad
  defp signature_status("U"), do: :good_unknown_validity
  defp signature_status("X"), do: :good_expired
  defp signature_status("Y"), do: :good_expired_key
  defp signature_status("R"), do: :good_revoked_key
  defp signature_status("E"), do: :cannot_check
  defp signature_status("N"), do: :no_signature
  defp signature_status(_status), do: :unknown

  # A symbolic reference such as refs/remotes/origin/HEAD only repeats a branch
  # that is already labelled, so it is left out.
  defp labels_by_commit(branches, tags) do
    branches
    |> Enum.reject(& &1.symbolic_target)
    |> Kernel.++(tags)
    |> Enum.group_by(& &1.target)
  end

  defp parse_tags(output) do
    output
    |> records()
    |> Enum.reduce_while({:ok, []}, fn record, {:ok, tags} ->
      case String.split(record, <<0>>, trim: false) do
        [full_name, name, object, dereferenced, type, ""] ->
          tag = %Tag{
            name: name,
            full_name: full_name,
            object: object,
            target: if(dereferenced == "", do: object, else: dereferenced),
            annotated?: type == "tag"
          }

          {:cont, {:ok, [tag | tags]}}

        _invalid ->
          {:halt, {:error, Error.new(:invalid_output, "Git returned invalid tag data")}}
      end
    end)
    |> case do
      {:ok, tags} -> {:ok, Enum.sort_by(tags, &String.downcase(&1.name))}
      error -> error
    end
  end

  defp tracking_count(track, direction) do
    case Regex.run(~r/#{direction} (\d+)/, track, capture: :all_but_first) do
      [count] -> String.to_integer(count)
      _no_count -> 0
    end
  end

  defp remote_name(:local, _name), do: nil

  defp remote_name(:remote, name) do
    case String.split(name, "/", parts: 2) do
      [remote, _branch] -> remote
      _invalid -> nil
    end
  end

  defp local_name_for_remote(%Branch{name: name, remote: remote}) when is_binary(remote) do
    String.replace_prefix(name, remote <> "/", "")
  end

  defp local_name_for_remote(%Branch{name: name}), do: name

  defp validate_branch_name(repository, name) do
    with {:ok, name} <- text_argument(name, "Branch name") do
      case Command.capture(repository, ["check-ref-format", "--branch", name]) do
        {:system_error, error} ->
          {:error, error}

        {output, 0} ->
          if output_line(output) == name do
            {:ok, name}
          else
            {:error, Error.new(:invalid_argument, "Invalid branch name")}
          end

        {_output, _status} ->
          {:error, Error.new(:invalid_argument, "Invalid branch name")}
      end
    end
  end

  defp find_branch(repository, name, kind) do
    with {:ok, name} <- text_argument(name, "Branch name"),
         {:ok, branches} <- list_branches(repository) do
      case Enum.find(branches, &(&1.kind == kind and &1.name == name)) do
        nil -> {:error, Error.new(:invalid_argument, "Branch #{inspect(name)} does not exist")}
        branch -> {:ok, branch}
      end
    end
  end

  defp validate_remote(repository, remote) do
    with {:ok, remote} <- text_argument(remote, "Remote name"),
         {:ok, output} <- Command.run(repository, ["remote"]) do
      if remote in lines(output) do
        {:ok, remote}
      else
        {:error, Error.new(:invalid_argument, "Remote #{inspect(remote)} does not exist")}
      end
    end
  end

  # Git may store a separate pushurl. Removing it makes pushes inherit the URL
  # we just changed and avoids leaving an HTTPS credential path behind.
  defp clear_remote_push_urls(repository, remote) do
    case Command.capture(repository, ["config", "--unset-all", "remote.#{remote}.pushurl"]) do
      {:system_error, error} ->
        {:error, error}

      {_output, status} when status in [0, 5] ->
        :ok

      {output, status} ->
        {:error,
         Error.command(
           ["config", "--unset-all", "remote.#{remote}.pushurl"],
           status,
           output
         )}
    end
  end

  defp resolve_commits(repository, revisions) do
    Enum.reduce_while(revisions, {:ok, []}, fn revision, {:ok, commits} ->
      case resolve_commit(repository, revision) do
        {:ok, commit} -> {:cont, {:ok, [commit | commits]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, commits} -> {:ok, Enum.reverse(commits)}
      error -> error
    end
  end

  defp revision_list(revisions) when is_binary(revisions), do: revision_list([revisions])

  defp revision_list(revisions) when is_list(revisions) and revisions != [] do
    if Enum.all?(revisions, &is_binary/1) do
      {:ok, revisions}
    else
      {:error, Error.new(:invalid_argument, "Revisions must be strings")}
    end
  end

  defp revision_list(_revisions),
    do: {:error, Error.new(:invalid_argument, "At least one revision is required")}

  defp commit_message(message) do
    with {:ok, message} <- text_argument(message, "Commit message") do
      if String.trim(message) == "" do
        {:error, Error.new(:invalid_argument, "Commit message cannot be blank")}
      else
        {:ok, message}
      end
    end
  end

  defp optional_message_args(nil), do: {:ok, []}

  defp optional_message_args(message) do
    case commit_message(message) do
      {:ok, message} -> {:ok, ["-m", message]}
      error -> error
    end
  end

  defp stash_message_args(nil), do: {:ok, []}

  defp stash_message_args(message) do
    with {:ok, message} <- text_argument(message, "Stash message") do
      if String.trim(message) == "" do
        {:error, Error.new(:invalid_argument, "Stash message cannot be blank")}
      else
        {:ok, ["--message", message]}
      end
    end
  end

  defp signing_args(false), do: {:ok, []}
  defp signing_args(true), do: {:ok, ["-S"]}

  defp signing_args(key) when is_binary(key) do
    with {:ok, key} <- text_argument(key, "Signing key") do
      {:ok, ["--gpg-sign=#{key}"]}
    end
  end

  defp signing_args(_value),
    do: {:error, Error.new(:invalid_argument, "Sign must be true, false, or a signing key")}

  defp mainline_args(nil), do: {:ok, []}

  defp mainline_args(parent) when is_integer(parent) and parent > 0,
    do: {:ok, ["-m", to_string(parent)]}

  defp mainline_args(_parent),
    do: {:error, Error.new(:invalid_argument, "Mainline parent must be a positive integer")}

  defp boolean_option(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_boolean(value) -> {:ok, value}
      _invalid -> {:error, Error.new(:invalid_argument, "#{key} must be a boolean")}
    end
  end

  defp push_remote_args(_repository, nil), do: {:ok, []}

  defp push_remote_args(repository, remote) do
    with {:ok, remote} <- validate_remote(repository, remote) do
      {:ok, ["--repo=#{remote}"]}
    end
  end

  defp push_branch_args(_repository, nil), do: {:ok, []}

  defp push_branch_args(repository, branch) do
    with {:ok, branch} <- find_branch(repository, branch, :local) do
      {:ok, ["refs/heads/#{branch.name}"]}
    end
  end

  defp find_stash(repository, reference) do
    with {:ok, reference} <- text_argument(reference, "Stash reference"),
         {:ok, stashes} <- list_stashes(repository) do
      case Enum.find(stashes, &(&1.reference == reference)) do
        nil ->
          {:error, Error.new(:invalid_argument, "Stash #{inspect(reference)} does not exist")}

        stash ->
          {:ok, stash}
      end
    end
  end

  defp selected_pathspecs(repository, paths) when is_list(paths) and paths != [] do
    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, pathspecs} ->
      case selected_pathspec(repository, path) do
        {:ok, pathspec} -> {:cont, {:ok, [pathspec | pathspecs]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, pathspecs} -> {:ok, Enum.reverse(pathspecs)}
      error -> error
    end
  end

  defp selected_pathspecs(_repository, _paths) do
    {:error, Error.new(:invalid_argument, "At least one file path is required")}
  end

  defp selected_pathspec(repository, path) do
    with {:ok, path} <- text_argument(path, "File path") do
      expanded = Path.expand(path, repository.path)
      relative = Path.relative_to(expanded, repository.path)

      cond do
        relative == "." ->
          {:error, Error.new(:invalid_argument, "File path must identify a file")}

        outside_repository?(relative) ->
          {:error, Error.new(:invalid_argument, "File path is outside the repository")}

        true ->
          {:ok, ":(top,literal)#{relative}"}
      end
    end
  end

  defp outside_repository?(path) do
    path == ".." or Path.type(path) == :absolute or String.starts_with?(path, "../")
  end

  defp rewrite_commit_message(repository, target, current_head, message) do
    with {:ok, _branch} <- require_attached_branch(repository),
         :ok <- ensure_ancestor(repository, target, current_head),
         :ok <- ensure_clean(repository),
         {:ok, metadata} <- replacement_metadata(repository, target),
         {:ok, replacement} <- create_replacement_commit(repository, metadata, message) do
      case run_mutation(repository, :edit_commit_message, [
             "rebase",
             "--rebase-merges",
             "--onto",
             replacement,
             target,
             current_head
           ]) do
        {:ok, result} ->
          {:ok, %{result | output: "Created replacement #{replacement}\n" <> result.output}}

        error ->
          error
      end
    end
  end

  defp require_attached_branch(repository) do
    case current_branch(repository) do
      {:ok, nil} ->
        {:error, Error.new(:unsupported, "Editing an older commit requires a checked-out branch")}

      result ->
        result
    end
  end

  defp ensure_ancestor(repository, ancestor, descendant) do
    case Command.capture(repository, ["merge-base", "--is-ancestor", ancestor, descendant]) do
      {:system_error, error} -> {:error, error}
      {_output, 0} -> :ok
      {_output, 1} -> {:error, Error.new(:invalid_argument, "Commit is not an ancestor of HEAD")}
      {output, status} -> {:error, Error.command(["merge-base", "--is-ancestor"], status, output)}
    end
  end

  defp ensure_clean(repository) do
    case Command.run(repository, ["status", "--porcelain"]) do
      {:ok, ""} -> :ok
      {:ok, _changes} -> {:error, Error.new(:invalid_argument, "Working tree must be clean")}
      {:error, error} -> {:error, error}
    end
  end

  defp replacement_metadata(repository, target) do
    format = "%T%x00%P%x00%an%x00%ae%x00%aI"

    with {:ok, output} <-
           Command.run(repository, ["show", "--no-patch", "--format=#{format}", target]) do
      case String.split(String.trim_trailing(output, "\n"), <<0>>, trim: false) do
        [tree, parents, author_name, author_email, authored_at] ->
          {:ok,
           %{
             tree: tree,
             parents: words(parents),
             author_name: author_name,
             author_email: author_email,
             authored_at: authored_at
           }}

        _invalid ->
          {:error, Error.new(:invalid_output, "Git returned invalid commit metadata")}
      end
    end
  end

  defp create_replacement_commit(repository, metadata, message) do
    parent_args = Enum.flat_map(metadata.parents, &["-p", &1])

    env = [
      {"GIT_AUTHOR_NAME", metadata.author_name},
      {"GIT_AUTHOR_EMAIL", metadata.author_email},
      {"GIT_AUTHOR_DATE", metadata.authored_at}
    ]

    with {:ok, output} <-
           Command.run(
             repository,
             ["commit-tree", metadata.tree] ++ parent_args ++ ["-m", message],
             env: env
           ) do
      {:ok, output_line(output)}
    end
  end

  defp require_operation(repository) do
    case operation(repository) do
      {:ok, nil} -> {:error, Error.new(:invalid_argument, "No Git operation is in progress")}
      result -> result
    end
  end

  defp continuation_args(:merge), do: {:ok, ["merge", "--continue"]}
  defp continuation_args(:rebase), do: {:ok, ["rebase", "--continue"]}
  defp continuation_args(:cherry_pick), do: {:ok, ["cherry-pick", "--continue"]}
  defp continuation_args(:revert), do: {:ok, ["revert", "--continue"]}
  defp continuation_args(kind), do: unsupported_operation(kind, "continued")

  defp skip_args(:rebase), do: {:ok, ["rebase", "--skip"]}
  defp skip_args(:cherry_pick), do: {:ok, ["cherry-pick", "--skip"]}
  defp skip_args(:revert), do: {:ok, ["revert", "--skip"]}
  defp skip_args(kind), do: unsupported_operation(kind, "skipped")

  defp abort_args(:merge), do: {:ok, ["merge", "--abort"]}
  defp abort_args(:rebase), do: {:ok, ["rebase", "--abort"]}
  defp abort_args(:cherry_pick), do: {:ok, ["cherry-pick", "--abort"]}
  defp abort_args(:revert), do: {:ok, ["revert", "--abort"]}
  defp abort_args(kind), do: unsupported_operation(kind, "aborted")

  defp unsupported_operation(kind, action) do
    {:error, Error.new(:unsupported, "#{kind} cannot be #{action} by this backend")}
  end

  defp rebase_operation(repository, directory, current_file, total_file) do
    %Operation{
      kind: :rebase,
      original_head: read_optional(Path.join(repository.git_dir, "ORIG_HEAD")),
      targets: words(read_optional(Path.join(directory, "onto")) || ""),
      current: read_integer(Path.join(directory, current_file)),
      total: read_integer(Path.join(directory, total_file)),
      message: read_optional(Path.join(directory, "message"))
    }
  end

  defp marker_operation(repository, kind, marker) do
    %Operation{
      kind: kind,
      original_head: read_optional(Path.join(repository.git_dir, "ORIG_HEAD")),
      targets: words(read_optional(Path.join(repository.git_dir, marker)) || ""),
      message: read_optional(Path.join(repository.git_dir, "MERGE_MSG"))
    }
  end

  defp read_optional(path) do
    case File.read(path) do
      {:ok, value} -> String.trim_trailing(value)
      {:error, _reason} -> nil
    end
  end

  defp read_integer(path) do
    case read_optional(path) do
      nil ->
        nil

      value ->
        case Integer.parse(value) do
          {number, ""} when number > 0 -> number
          _invalid -> nil
        end
    end
  end

  defp run_mutation(repository, action, args) do
    case Command.run(repository, args) do
      {:ok, output} ->
        {:ok, %CommandResult{action: action, output: String.trim_trailing(output)}}

      {:error, error} ->
        {:error, with_operation(repository, error)}
    end
  end

  defp with_operation(repository, error) do
    case operation(repository) do
      {:ok, %Operation{} = operation} ->
        %{error | kind: :conflict, operation: operation}

      _no_operation ->
        error
    end
  end

  defp text_argument(value, label) when is_binary(value) do
    cond do
      value == "" ->
        {:error, Error.new(:invalid_argument, "#{label} cannot be empty")}

      String.contains?(value, <<0>>) ->
        {:error, Error.new(:invalid_argument, "#{label} contains a null byte")}

      true ->
        {:ok, value}
    end
  end

  defp text_argument(_value, label),
    do: {:error, Error.new(:invalid_argument, "#{label} must be a string")}

  defp records(output) do
    output
    |> String.split(<<30>>, trim: false)
    |> Enum.map(&String.trim_leading/1)
    |> Enum.reject(&(String.trim(&1) == ""))
  end

  defp words(value), do: String.split(value, ~r/\s+/, trim: true)
  defp lines(value), do: String.split(value, ~r/\r?\n/, trim: true)

  defp output_line(output) do
    output
    |> String.trim_trailing("\n")
    |> String.trim_trailing("\r")
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp if_args(true, argument), do: [argument]
  defp if_args(false, _argument), do: []
end
