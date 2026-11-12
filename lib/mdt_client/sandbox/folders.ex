defmodule MDTClient.Sandbox.Folders do
  @moduledoc """
  The VM's own folders on this machine, which survive recreating it:

    * `home` - mounted at `/root`: logins, shell history, Zed's server, agent
      settings;
    * `cache` - mounted at `/cache`: tool versions installed at runtime and
      package caches;
    * `snapshots` - copies of `home` taken before each recreate, at most
      three, so an older image tag can come back with the Home it had;
    * `optmem` - mounted at `/root/.optmem`: the VM's own memory, which
      emptying Home leaves alone.

  The VM writes all of them, so MDT treats what is inside as data: it copies,
  empties and lists them, and never runs anything from them. Everything here
  runs in a task while the VM is stopped, never in the sandbox process.
  """

  alias MDTClient.Sandbox.Snapshot

  @kept 3

  @type paths :: %{home: Path.t(), cache: Path.t(), snapshots: Path.t(), optmem: Path.t()}

  @doc "Where the folders of the sandbox in `dir` live."
  @spec paths(Path.t()) :: paths()
  def paths(dir) do
    %{
      home: Path.join(dir, "home"),
      cache: Path.join(dir, "cache"),
      snapshots: Path.join(dir, "snapshots"),
      optmem: Path.join(dir, "optmem")
    }
  end

  @doc "Creates the folders, and the mount point the VM's memory needs inside Home."
  @spec ensure!(paths()) :: :ok
  def ensure!(paths) do
    Enum.each([paths.home, paths.cache, paths.snapshots, paths.optmem], &File.mkdir_p!/1)
    File.mkdir_p!(Path.join(paths.home, ".optmem"))
  end

  @doc "Whether a folder holds nothing (or doesn't exist)."
  @spec empty?(Path.t()) :: boolean()
  def empty?(dir) do
    case File.ls(dir) do
      {:ok, entries} -> Enum.reject(entries, &(&1 == ".optmem")) == []
      {:error, _} -> true
    end
  end

  @doc "Removes everything inside `dir`, keeping the folder."
  @spec empty!(Path.t()) :: :ok
  def empty!(dir) do
    case File.ls(dir) do
      {:ok, entries} -> Enum.each(entries, &File.rm_rf!(Path.join(dir, &1)))
      {:error, _} -> :ok
    end

    File.mkdir_p!(dir)
    :ok
  end

  @doc """
  Copies Home into a new snapshot labelled with `tag`. On btrfs and XFS the
  copy shares blocks with Home until either changes, so it is instant.
  """
  @spec snapshot!(paths(), String.t() | nil, DateTime.t()) :: Snapshot.t()
  def snapshot!(paths, tag, now) do
    id = Calendar.strftime(now, "%Y%m%dT%H%M%S") <> "-" <> unique()
    copy!(paths.home, Path.join(paths.snapshots, id))
    %Snapshot{id: id, tag: tag, taken_at: now}
  end

  @doc "Replaces Home with a copy of `snapshot`, which stays as it was."
  @spec restore!(paths(), Snapshot.t()) :: :ok
  def restore!(paths, %Snapshot{id: id}) do
    source = Path.join(paths.snapshots, id)
    unless File.dir?(source), do: raise("snapshot #{id} is gone")
    File.rm_rf!(paths.home)
    copy!(source, paths.home)
  end

  @doc """
  Splits `snapshots` into those kept, the newest #{@kept}, and those to
  delete.
  """
  @spec keep([Snapshot.t()], pos_integer()) :: {[Snapshot.t()], [Snapshot.t()]}
  def keep(snapshots, count \\ @kept),
    do: snapshots |> Enum.sort_by(& &1.taken_at, {:desc, DateTime}) |> Enum.split(count)

  @doc "Deletes a snapshot's copy."
  @spec delete!(paths(), Snapshot.t()) :: :ok
  def delete!(paths, %Snapshot{id: id}) do
    File.rm_rf!(Path.join(paths.snapshots, id))
    :ok
  end

  # cp keeps modes, links and times, and shares blocks where the file system
  # can (`--reflink=auto`); File.cp_r would follow symlinks the VM made.
  defp copy!(source, destination) do
    File.rm_rf!(destination)

    case System.cmd("cp", ["-a", "--reflink=auto", source, destination], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {output, status} -> raise "copying #{source} failed (#{status}): #{String.trim(output)}"
    end
  end

  defp unique, do: :crypto.strong_rand_bytes(3) |> Base.encode16(case: :lower)
end
