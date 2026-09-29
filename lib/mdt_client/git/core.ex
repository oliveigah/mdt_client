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
  alias MDTClient.Git.FileChange
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

  @metadata_fields ["%H", "%P", "%an", "%ae", "%aI", "%cn", "%ce", "%cI", "%s", "%b"]

  # Checking a signature runs gpg or ssh-keygen once per signed commit, which on
  # a repository that signs its history costs more than the rest of a snapshot
  # put together. The graph leaves it out; one commit is checked on request.
  @graph_format Enum.join(@metadata_fields, "%x00") <> "%x00%x1e"
  @commit_format Enum.join(@metadata_fields ++ ["%G?", "%GS"], "%x00") <> "%x00%x1e"
  @signature_format "%G?%x00%GS"

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

  @stash_format Enum.join(["%gd", "%H", "%P", "%gs", "%cI"], "%x00") <> "%x00%x1e"
  @fingerprint_ref_format "%(refname)%00%(objectname)%00%(upstream:track)%00"

  @reset_modes [:fast_forward, :soft, :hard, :stash]

  @type result(value) :: {:ok, value} | {:error, Error.t()}
  @type mutation_result :: result(CommandResult.t())
  @type reset_mode :: :fast_forward | :soft | :hard | :stash

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

  @doc """
  Loads the dynamic state used by the branch list and graph.

  Commits leave their signature unchecked (`signature_status: nil`) unless
  `signatures: true` is given; `signature/2` checks one commit on its own.
  """
  @spec snapshot(Repository.t(), keyword()) :: result(Snapshot.t())
  def snapshot(%Repository{} = repository, opts \\ []) do
    with {:ok, limit} <- graph_limit(opts),
         {:ok, signatures?} <- boolean_option(opts, :signatures, false) do
      # The log does not wait for the references: `--all` already walks from
      # every one of them and from HEAD, and labels are matched up afterwards.
      [head, current_branch, branches, tags, operation, log] =
        [
          fn -> head(repository) end,
          fn -> current_branch(repository) end,
          fn -> list_branches(repository) end,
          fn -> list_tags(repository) end,
          fn -> operation(repository) end,
          fn -> read_log(repository, limit, signatures?) end
        ]
        |> Enum.map(&Task.async/1)
        |> Task.await_many(:infinity)

      build_snapshot(
        repository,
        head,
        current_branch,
        branches,
        tags,
        operation,
        log
      )
    end
  end

  defp build_snapshot(
         repository,
         head_result,
         current_branch_result,
         branches_result,
         tags_result,
         operation_result,
         log_result
       ) do
    with {:ok, head} <- head_result,
         {:ok, current_branch} <- current_branch_result,
         {:ok, branches} <- branches_result,
         {:ok, tags} <- tags_result,
         {:ok, log} <- log_result,
         {:ok, commits} <- parse_commits(log, labels_by_commit(branches, tags)),
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

  @doc """
  Returns commits in topological order, ready for graph layout.

  Accepts the same `:limit` and `:signatures` options as `snapshot/2`.
  """
  @spec graph(Repository.t(), keyword()) :: result([Commit.t()])
  def graph(%Repository{} = repository, opts \\ []) do
    with {:ok, limit} <- graph_limit(opts),
         {:ok, signatures?} <- boolean_option(opts, :signatures, false),
         {:ok, branches} <- list_branches(repository),
         {:ok, tags} <- list_tags(repository),
         {:ok, log} <- read_log(repository, limit, signatures?) do
      parse_commits(log, labels_by_commit(branches, tags))
    end
  end

  @doc """
  Checks the signature of one commit-ish.

  Returns the same `signature_status` and `signature_signer` values
  `get_commit/2` fills in, without loading anything else.
  """
  @spec signature(Repository.t(), String.t()) ::
          result({Commit.signature_status(), String.t() | nil})
  def signature(%Repository{} = repository, revision) do
    with {:ok, revision} <- text_argument(revision, "Revision"),
         {:ok, output} <-
           Command.run(repository, [
             "show",
             "--no-patch",
             "--format=#{@signature_format}",
             "--end-of-options",
             "#{revision}^{commit}"
           ]) do
      case String.split(output_line(output), <<0>>, parts: 2) do
        [status, signer] -> {:ok, {signature_status(status), blank_to_nil(signer)}}
        _invalid -> {:error, Error.new(:invalid_output, "Git returned invalid signature data")}
      end
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

  @doc """
  Checks out an existing local branch and moves it to a remote branch.

  This is checking a remote branch out when a local one already stands for it:
  rather than creating another, the local branch is brought in line. `mode`
  decides what happens to the work that move would otherwise lose:

    * `:fast_forward` only advances the branch, and fails when it has commits
      the remote branch lacks, so nothing is lost;
    * `:soft` keeps those commits and any uncommitted change as staged changes;
    * `:hard` discards both;
    * `:stash` stashes uncommitted changes, untracked files included, before a
      hard reset, so only the commits the local branch alone had are dropped.
  """
  @spec reset_to_remote(Repository.t(), String.t(), String.t(), reset_mode()) ::
          mutation_result()
  def reset_to_remote(%Repository{} = repository, local_name, remote_branch, mode)
      when mode in @reset_modes do
    with {:ok, local} <- find_branch(repository, local_name, :local),
         {:ok, remote} <- find_branch(repository, remote_branch, :remote),
         {:ok, target} <- resolve_commit(repository, remote.full_name) do
      message = "Before resetting #{local.name} to #{remote.name}"
      stash = ["stash", "push", "--include-untracked", "--message", message]

      commands =
        if_args(mode == :stash, stash) ++
          reset_switch(local, mode) ++ [reset_move(mode, target)]

      run_mutations(commands, repository, :reset_to_remote)
    end
  end

  def reset_to_remote(%Repository{}, _local_name, _remote_branch, _mode),
    do: {:error, Error.new(:invalid_argument, "Unknown reset mode")}

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

  @doc """
  Discards every change to the selected files, returning them to HEAD.

  Staged and unstaged edits are both dropped, and a new file, staged or
  untracked, is deleted. Paths Git reports no change for are left alone, so a
  stale selection cannot touch an unchanged or ignored file. Undoing a staged
  rename restores the path it came from as well; if an untracked file has since
  taken that path and is not selected too, only the index is restored so the
  file survives. Unstaged and untracked content is kept nowhere else, so a
  discard cannot be undone.
  """
  @spec discard(Repository.t(), [Path.t()]) :: mutation_result()
  def discard(%Repository{} = repository, paths) do
    with {:ok, relatives} <- selected_paths(repository, paths),
         {:ok, changes} <- Files.status(repository),
         {:ok, head} <- head(repository) do
      plan = discard_plan(changes, relatives)

      [
        restore_args(head, plan.restore),
        restore_index_args(plan.restore_index),
        clean_args(plan.remove)
      ]
      |> Enum.reject(&is_nil/1)
      |> run_mutations(repository, :discard)
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

  @doc """
  Squashes consecutive commits on the checked-out branch into one.

  The commits must follow one another on the branch's first-parent line, and
  none may be a merge. The squashed commit carries the newest one's tree, the
  oldest one's parent and author, and `message`; whatever came after the newest
  is replayed on top of it. Like any history rewrite this needs a clean
  worktree and gives every rewritten commit a new id.
  """
  @spec squash(Repository.t(), [String.t()], String.t()) :: mutation_result()
  def squash(%Repository{} = repository, revisions, message) do
    with {:ok, revisions} <- revision_list(revisions),
         {:ok, message} <- commit_message(message),
         {:ok, commits} <- resolve_commits(repository, revisions),
         {:ok, [newest | _] = chain} <- squash_chain(repository, Enum.uniq(commits)),
         {:ok, branch} <- require_attached_branch(repository),
         {:ok, current_head} <- require_head(repository),
         :ok <- ensure_first_parent(repository, newest, current_head),
         :ok <- ensure_clean(repository),
         {:ok, newest_metadata} <- replacement_metadata(repository, newest),
         {:ok, oldest_metadata} <- replacement_metadata(repository, List.last(chain)),
         {:ok, replacement} <-
           create_replacement_commit(
             repository,
             %{oldest_metadata | tree: newest_metadata.tree},
             message
           ) do
      rewrite_onto(repository, :squash, replacement, newest, branch)
    end
  end

  @doc """
  Fetches and prunes either every remote or one named remote.

  Pass `prompt: false` for a fetch nobody asked for, such as one run on a
  timer: credential helpers and SSH askpass programs are told not to open a
  window, so a remote that needs a password fails instead of interrupting.
  """
  @spec fetch(Repository.t(), String.t() | nil, keyword()) :: mutation_result()
  def fetch(repository, remote \\ nil, opts \\ [])

  def fetch(%Repository{} = repository, nil, opts) do
    with {:ok, command_opts} <- fetch_options(opts) do
      run_mutation(repository, :fetch, ["fetch", "--all", "--prune"], command_opts)
    end
  end

  def fetch(%Repository{} = repository, remote, opts) do
    with {:ok, remote} <- validate_remote(repository, remote),
         {:ok, command_opts} <- fetch_options(opts) do
      run_mutation(repository, :fetch, ["fetch", "--prune", "--", remote], command_opts)
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

  # `--all` walks from every reference and from HEAD, detached or not, except
  # the stash: its commits are Git's bookkeeping for one entry (the index, the
  # untracked files) rather than history, and `list_stashes/1` reports each
  # entry with the commit it was made on instead.
  defp read_log(repository, limit, signatures?) do
    format = if signatures?, do: @commit_format, else: @graph_format

    Command.run(repository, [
      "log",
      "--topo-order",
      "--max-count=#{limit}",
      "--format=#{format}",
      "--exclude=refs/stash",
      "--all"
    ])
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

    # Only the newest stash has a reference; dropping an older one rewrites the
    # stash reflog and nothing else.
    stash_log = Path.join(repository.common_dir, "logs/refs/stash")

    [{"logs/refs/stash", file_signature(stash_log)} | marker_contents]
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
        [reference, commit, parents, summary, created_at, ""] ->
          with {:ok, index} <- stash_index(reference),
               {:ok, created_at} <- parse_datetime(created_at),
               [parent | others] <- words(parents) do
            stash = %Stash{
              index: index,
              reference: reference,
              commit: commit,
              parent: parent,
              summary: summary,
              created_at: created_at,
              untracked?: length(others) > 1
            }

            {:cont, {:ok, [stash | stashes]}}
          else
            {:error, error} ->
              {:halt, {:error, error}}

            [] ->
              {:halt, {:error, Error.new(:invalid_output, "Git returned a stash with no base")}}
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

  # A record holds the metadata fields, then the signature fields when they
  # were asked for, then the empty field before the record separator.
  defp parse_commit(record, labels) do
    case String.split(record, <<0>>, trim: false) do
      [_id, _parents, _an, _ae, _aI, _cn, _ce, _cI, _summary, _body, status, signer, ""] = fields ->
        build_commit(fields, labels, signature_status(status), blank_to_nil(signer))

      [_id, _parents, _an, _ae, _aI, _cn, _ce, _cI, _summary, _body, ""] = fields ->
        build_commit(fields, labels, nil, nil)

      _invalid ->
        {:error, Error.new(:invalid_output, "Git returned invalid commit data")}
    end
  end

  defp build_commit(fields, labels, signature_status, signature_signer) do
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
      body | _signature
    ] = fields

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
         signature_status: signature_status,
         signature_signer: signature_signer,
         labels: Map.get(labels, id, [])
       }}
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

  # A hard reset throws the uncommitted changes away anyway, so they are not
  # allowed to stop the checkout; every other mode keeps them, and a checkout
  # they would be overwritten by fails before anything moved.
  defp reset_switch(%Branch{current?: true}, _mode), do: []
  defp reset_switch(local, :hard), do: [["switch", "--discard-changes", "--", local.name]]
  defp reset_switch(local, _mode), do: [["switch", "--", local.name]]

  defp reset_move(:fast_forward, target), do: ["merge", "--ff-only", target]
  defp reset_move(:soft, target), do: ["reset", "--soft", target]
  defp reset_move(_hard_or_stash, target), do: ["reset", "--hard", target]

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

  # GIT_TERMINAL_PROMPT, set for every command, only covers the terminal; these
  # cover the graphical prompts OpenSSH and Git Credential Manager fall back to.
  defp fetch_options(opts) do
    with {:ok, prompt?} <- boolean_option(opts, :prompt, true) do
      if prompt? do
        {:ok, []}
      else
        {:ok, env: [{"SSH_ASKPASS_REQUIRE", "never"}, {"GCM_INTERACTIVE", "never"}]}
      end
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

  defp selected_pathspecs(repository, paths) do
    with {:ok, relatives} <- selected_paths(repository, paths) do
      {:ok, Enum.map(relatives, &pathspec/1)}
    end
  end

  defp selected_paths(repository, paths) when is_list(paths) and paths != [] do
    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, relatives} ->
      case selected_path(repository, path) do
        {:ok, relative} -> {:cont, {:ok, [relative | relatives]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, relatives} -> {:ok, Enum.reverse(relatives)}
      error -> error
    end
  end

  defp selected_paths(_repository, _paths) do
    {:error, Error.new(:invalid_argument, "At least one file path is required")}
  end

  defp selected_path(repository, path) do
    with {:ok, path} <- text_argument(path, "File path") do
      expanded = Path.expand(path, repository.path)
      relative = Path.relative_to(expanded, repository.path)

      cond do
        relative == "." ->
          {:error, Error.new(:invalid_argument, "File path must identify a file")}

        outside_repository?(relative) ->
          {:error, Error.new(:invalid_argument, "File path is outside the repository")}

        true ->
          {:ok, relative}
      end
    end
  end

  defp pathspec(relative), do: ":(top,literal)" <> relative

  # `git restore` does not know untracked files, so those are cleaned instead.
  # A staged rename is a deletion of the old path plus an addition of the new
  # one, and undoing only the addition would leave the old path deleted.
  defp discard_plan(changes, relatives) do
    selected = MapSet.new(relatives)
    chosen = Enum.filter(changes, &MapSet.member?(selected, &1.path))
    {new, tracked} = Enum.split_with(chosen, & &1.untracked?)
    untracked = MapSet.new(for change <- changes, change.untracked?, do: change.path)
    origins = for %FileChange{original_path: origin} <- tracked, is_binary(origin), do: origin

    # The old path of a rename may since hold an untracked file of its own.
    {occupied, origins} =
      Enum.split_with(origins, fn origin ->
        MapSet.member?(untracked, origin) and not MapSet.member?(selected, origin)
      end)

    %{
      restore: Enum.uniq(Enum.map(tracked, & &1.path) ++ origins),
      restore_index: Enum.uniq(occupied),
      remove: for(change <- new, change.path not in origins, do: change.path)
    }
  end

  defp restore_args(_head, []), do: nil

  # Without a commit there is nothing to restore from: every tracked file is a
  # staged addition, and discarding it removes it from the index and the disk.
  defp restore_args(nil, paths),
    do: ["rm", "--force", "--quiet", "--ignore-unmatch", "--" | Enum.map(paths, &pathspec/1)]

  defp restore_args(_head, paths),
    do: [
      "restore",
      "--source=HEAD",
      "--staged",
      "--worktree",
      "--" | Enum.map(paths, &pathspec/1)
    ]

  defp restore_index_args([]), do: nil

  defp restore_index_args(paths),
    do: ["restore", "--source=HEAD", "--staged", "--" | Enum.map(paths, &pathspec/1)]

  defp clean_args([]), do: nil
  defp clean_args(paths), do: ["clean", "--force", "--" | Enum.map(paths, &pathspec/1)]

  defp outside_repository?(path) do
    path == ".." or Path.type(path) == :absolute or String.starts_with?(path, "../")
  end

  defp rewrite_commit_message(repository, target, current_head, message) do
    with {:ok, branch} <- require_attached_branch(repository),
         :ok <- ensure_ancestor(repository, target, current_head),
         :ok <- ensure_clean(repository),
         {:ok, metadata} <- replacement_metadata(repository, target),
         {:ok, replacement} <- create_replacement_commit(repository, metadata, message) do
      rewrite_onto(repository, :edit_commit_message, replacement, target, branch)
    end
  end

  # Replays what the branch has after `target` onto `replacement`. The branch is
  # named rather than HEAD's id: given an id, Git rebases a detached HEAD and
  # leaves the branch where it was.
  defp rewrite_onto(repository, action, replacement, target, branch) do
    args = ["rebase", "--rebase-merges", "--onto", replacement, target, branch]

    case run_mutation(repository, action, args) do
      {:ok, result} ->
        {:ok, %{result | output: "Created replacement #{replacement}\n" <> result.output}}

      error ->
        error
    end
  end

  defp require_attached_branch(repository) do
    case current_branch(repository) do
      {:ok, nil} ->
        {:error, Error.new(:unsupported, "Rewriting history requires a checked-out branch")}

      result ->
        result
    end
  end

  # Orders the commits newest first, and insists each one's only parent is the
  # next: anything else would need reordering, or would flatten a merge.
  defp squash_chain(_repository, [_single]),
    do: {:error, Error.new(:invalid_argument, "Squashing needs at least two commits")}

  defp squash_chain(repository, commits) do
    with {:ok, output} <-
           Command.run(repository, ["show", "--no-patch", "--format=%H %P" | commits]) do
      parents =
        for line <- lines(output), into: %{} do
          [id | ids] = words(line)
          {id, ids}
        end

      if Enum.any?(parents, fn {_id, ids} -> length(ids) > 1 end) do
        {:error, Error.new(:invalid_argument, "A merge commit cannot be squashed")}
      else
        # The newest is the one no other selected commit names as its parent.
        firsts = MapSet.new(parents, fn {_id, ids} -> List.first(ids) end)
        newest = Enum.reject(commits, &MapSet.member?(firsts, &1))
        chain = walk_chain(newest, parents, MapSet.new(commits))

        if length(chain) == length(commits),
          do: {:ok, chain},
          else: {:error, Error.new(:invalid_argument, "Only consecutive commits can be squashed")}
      end
    end
  end

  defp walk_chain([newest], parents, selected) do
    Stream.unfold(newest, fn id ->
      if id && MapSet.member?(selected, id), do: {id, List.first(parents[id])}
    end)
    |> Enum.to_list()
  end

  defp walk_chain(_heads, _parents, _selected), do: []

  # `commit` sits on the branch's own line when walking first parents down from
  # HEAD reaches it, which is when HEAD~n, n being that walk's length, is it.
  defp ensure_first_parent(repository, commit, head) do
    with {:ok, count} <-
           Command.run(repository, ["rev-list", "--count", "--first-parent", "#{commit}..#{head}"]),
         {:ok, found} <- resolve_commit(repository, "#{head}~#{String.trim(count)}") do
      if found == commit,
        do: :ok,
        else:
          {:error,
           Error.new(:invalid_argument, "Only commits on the checked-out branch can be squashed")}
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

  defp run_mutation(repository, action, args, opts \\ []) do
    case Command.run(repository, args, opts) do
      {:ok, output} ->
        {:ok, %CommandResult{action: action, output: String.trim_trailing(output)}}

      {:error, error} ->
        {:error, with_operation(repository, error)}
    end
  end

  # Runs the commands of one action in order, stopping at the first failure, and
  # reports them as a single result.
  defp run_mutations(commands, repository, action) do
    empty = {:ok, %CommandResult{action: action, output: ""}}

    Enum.reduce_while(commands, empty, fn args, {:ok, acc} ->
      case run_mutation(repository, action, args) do
        {:ok, result} ->
          output = [acc.output, result.output] |> Enum.reject(&(&1 == "")) |> Enum.join("\n")
          {:cont, {:ok, %{acc | output: output}}}

        error ->
          {:halt, error}
      end
    end)
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
