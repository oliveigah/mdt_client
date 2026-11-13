defmodule MDTClient.Sandbox.PullStore do
  @moduledoc """
  Where a pull request's commits wait until you bring them in: a bare git
  repository of MDT's own, one per repository of yours that pull requests
  are for, in the identity's sandbox folder.

  Nothing of the VM's is written into your repository while it waits. The
  store borrows your repository's objects instead (git's alternates: its
  `objects/info/alternates` names your `.git/objects`), so a pull request
  brings only what is new, and git can work out its base, its diff and
  whether it merges, all here, from both histories at once. Your
  repository is only read.

  What MDT works out to show you (a merge, a snapshot of your working tree)
  runs in `view/2`: git writes what it makes into a folder of its own that
  is deleted after, not into the store and not into your repository.

  Pull requests sit under `refs/pulls/<id>`.
  """

  alias MDTClient.Sandbox.{Guest, HostGit}

  @doc "The store for the repository whose top folder is `repo`, under the sandbox folder `dir`."
  @spec path(Path.t(), Path.t()) :: Path.t()
  def path(dir, repo) do
    hash = :crypto.hash(:sha256, repo) |> Base.encode16(case: :lower) |> binary_part(0, 16)
    Path.join([dir, "pulls", "#{Path.basename(repo)}-#{hash}.git"])
  end

  @doc """
  Makes the store when there is none, and points it at the repository's
  objects (again, every time: the repository may have moved its own).
  """
  @spec ensure(Path.t(), Path.t()) :: :ok | {:error, String.t()}
  def ensure(store, repo) do
    with objects when is_binary(objects) <- objects(repo) || {:error, "That repository is gone."},
         :ok <- init(store) do
      File.write(Path.join([store, "objects", "info", "alternates"]), objects <> "\n")
    end
  end

  defp init(store) do
    if File.dir?(Path.join(store, "objects")) do
      :ok
    else
      File.mkdir_p!(Path.dirname(store))

      case System.cmd("git", ["init", "--quiet", "--bare", store],
             env: Guest.git_env(),
             stderr_to_stdout: true
           ) do
        {_, 0} -> :ok
        {output, _} -> {:error, String.trim(output)}
      end
    end
  end

  # The objects folder of the repository, shared by all its worktrees.
  defp objects(repo) do
    case HostGit.line(repo, ["rev-parse", "--path-format=absolute", "--git-common-dir"]) do
      nil -> nil
      common -> Path.join(common, "objects")
    end
  end

  @doc """
  Fetches `branch` of the repository at `folder` in the VM into
  `refs/pulls/<id>`, under a limit on what git may write (in MiB). Returns
  the commit that arrived.
  """
  @spec receive(Path.t(), Guest.t(), Path.t(), String.t(), pos_integer(), pos_integer()) ::
          {:ok, String.t()} | {:error, :too_large | String.t()}
  def receive(store, guest, folder, branch, id, limit) do
    started = System.os_time(:second)

    case HostGit.run(
           store,
           ["fetch", "--no-tags", "--no-write-fetch-head", guest.git_url.(folder)] ++
             ["+refs/heads/#{branch}:#{ref(id)}"],
           env: guest.env,
           seconds: 600,
           file_limit: limit
         ) do
      {:ok, _} ->
        case HostGit.line(store, ["rev-parse", "--verify", "--quiet", ref(id)]) do
          nil -> {:error, "The branch did not arrive."}
          commit -> {:ok, commit}
        end

      {:error, text} ->
        # The kernel stops the write (SIGXFSZ, signal 25), and git says so
        # one way or the other.
        if text =~ ~r/died of signal 25|File too large|File size limit exceeded/i do
          sweep(store, started)
          {:error, :too_large}
        else
          {:error, text}
        end
    end
  end

  # What a fetch stopped halfway leaves: the files git was still writing.
  defp sweep(store, since) do
    objects = Path.join(store, "objects")

    for dir <- [objects | Enum.map(ls(objects), &Path.join(objects, &1))],
        name <- ls(dir),
        String.starts_with?(name, ["tmp_obj_", "tmp_pack_", "tmp_idx_", "tmp_rev_"]),
        path = Path.join(dir, name),
        {:ok, %File.Stat{type: :regular, mtime: mtime}} <- [File.stat(path, time: :posix)],
        mtime >= since,
        do: File.rm(path)

    :ok
  end

  defp ls(dir) do
    case File.ls(dir) do
      {:ok, names} -> names
      {:error, _} -> []
    end
  end

  @doc "The ref a pull request's commit sits at in the store."
  @spec ref(pos_integer()) :: String.t()
  def ref(id), do: "refs/pulls/#{id}"

  @doc "Lets go of a pull request's commit."
  @spec drop(Path.t(), pos_integer()) :: :ok
  def drop(store, id) do
    if File.dir?(store), do: HostGit.run(store, ["update-ref", "-d", ref(id)])
    :ok
  end

  @doc """
  Runs `fun` with the environment in which git, run in the store or in
  your repository, sees both histories and writes what it makes into a
  folder of its own, deleted when `fun` returns.
  """
  @spec view(Path.t(), ([{String.t(), String.t()}] -> result)) :: result when result: var
  def view(store, fun) do
    scratch = Path.join(System.tmp_dir!(), "mdt-view-#{System.unique_integer([:positive])}")
    File.mkdir_p!(scratch)

    try do
      fun.([
        {"GIT_OBJECT_DIRECTORY", scratch},
        # The store's own alternates lead on to your repository's objects.
        {"GIT_ALTERNATE_OBJECT_DIRECTORIES", Path.join(store, "objects")}
      ])
    after
      File.rm_rf(scratch)
    end
  end

  @doc """
  Brings a pull request's commits into your repository, at
  `refs/mdt/pulls/<id>`, a ref no tool lists as a branch. Done only when
  you bring it in.
  """
  @spec copy_into(Path.t(), Path.t(), pos_integer()) :: {:ok, String.t()} | {:error, String.t()}
  def copy_into(store, repo, id) do
    target = "refs/mdt/pulls/#{id}"

    with {:ok, _} <-
           HostGit.run(
             repo,
             ["fetch", "--no-tags", "--no-write-fetch-head", store, "+#{ref(id)}:#{target}"],
             seconds: 600
           ),
         commit when is_binary(commit) <- HostGit.line(repo, ["rev-parse", "--verify", target]) do
      {:ok, commit}
    else
      nil -> {:error, "The pull request's commits did not arrive in your repository."}
      {:error, reason} -> {:error, reason}
    end
  end
end
