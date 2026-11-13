defmodule MDTClient.Sandbox.Disks do
  @moduledoc """
  The VM's own disks: ext4 images in the identity's sandbox folder, which
  survive recreating the VM.

    * `home` - `/root`: agent logins and settings, shell history;
    * `cache` - `/cache`: tool versions installed at runtime, package caches;
    * `work` - `/work`: your projects and everything built in them;
    * `snapshots` - copies of `home` taken before each recreate, at most
      three, so an older image tag can come back with the Home it had.

  Work lives here, not in shared host folders, for two reasons. Nothing on
  the host opens these files, so nothing the VM writes in them can run
  here. And they are fast: small-file work is 4 to 8 times faster on a disk
  image than through a shared folder.

  The images are sparse: a 64 GiB disk takes host space only as it fills.
  They are made without root (`mkfs.ext4` on a plain file). The host never
  mounts them, so what is inside can be read only through the VM.

  Everything here runs in a task while the VM is stopped, never in the
  sandbox process. A disk the VM is using must not be copied or resized.
  """

  alias MDTClient.Sandbox.Snapshot

  @kept 3
  @names [:home, :cache, :work]

  @type name :: :home | :cache | :work
  @type paths :: %{
          dir: Path.t(),
          home: Path.t(),
          cache: Path.t(),
          work: Path.t(),
          snapshots: Path.t()
        }
  @type sizes :: %{home: pos_integer(), cache: pos_integer(), work: pos_integer()}

  @doc "The disks, in the order they are mounted."
  @spec names() :: [name()]
  def names, do: @names

  @doc "Where each disk mounts in the VM."
  @spec mount_point(name()) :: String.t()
  def mount_point(:home), do: "/root"
  def mount_point(:cache), do: "/cache"
  def mount_point(:work), do: "/work"

  @doc "Where the disks of the sandbox in `dir` live."
  @spec paths(Path.t()) :: paths()
  def paths(dir) do
    disks = Path.join(dir, "disks")

    %{
      dir: disks,
      home: Path.join(disks, "home.img"),
      cache: Path.join(disks, "cache.img"),
      work: Path.join(disks, "work.img"),
      snapshots: Path.join(dir, "disk-snapshots")
    }
  end

  @doc "The tools this needs and can't find, by name. Empty when all are there."
  @spec missing_tools() :: [String.t()]
  def missing_tools, do: for(tool <- ~w(mkfs.ext4 e2fsck resize2fs), is_nil(tool(tool)), do: tool)

  @doc """
  Makes the disks that don't exist yet, `sizes` GiB each, and grows any that
  is smaller than its size now. Never shrinks one.
  """
  @spec ensure!(paths(), sizes()) :: :ok
  def ensure!(paths, sizes) do
    File.mkdir_p!(paths.dir)
    File.mkdir_p!(paths.snapshots)

    for name <- @names do
      path = Map.fetch!(paths, name)
      wanted = Map.fetch!(sizes, name) * gib()

      case File.stat(path) do
        {:error, :enoent} -> make!(path, wanted)
        {:ok, %File.Stat{size: size}} when size < wanted -> grow!(path, wanted)
        {:ok, _big_enough} -> :ok
      end
    end

    :ok
  end

  @doc "Replaces a disk with an empty one of the same size."
  @spec empty!(Path.t()) :: :ok
  def empty!(path) do
    size =
      case File.stat(path) do
        {:ok, %File.Stat{size: size}} -> size
        {:error, _} -> raise "the disk #{path} doesn't exist"
      end

    File.rm!(path)
    make!(path, size)
  end

  @doc """
  Copies the Home disk into a new snapshot labelled with `tag`. On btrfs and
  XFS the copy shares blocks with the disk until either changes, so it is
  instant; elsewhere only the blocks in use are copied.
  """
  @spec snapshot!(paths(), String.t() | nil, DateTime.t()) :: Snapshot.t()
  def snapshot!(paths, tag, now) do
    id = Calendar.strftime(now, "%Y%m%dT%H%M%S") <> "-" <> unique()
    copy!(paths.home, snapshot_path(paths, id))
    %Snapshot{id: id, tag: tag, taken_at: now}
  end

  @doc "Replaces the Home disk with a copy of `snapshot`, which stays as it was."
  @spec restore!(paths(), Snapshot.t()) :: :ok
  def restore!(paths, %Snapshot{id: id}) do
    source = snapshot_path(paths, id)
    unless File.regular?(source), do: raise("snapshot #{id} is gone")
    copy!(source, paths.home)
  end

  @doc "Splits `snapshots` into those kept, the newest #{@kept}, and those to delete."
  @spec keep([Snapshot.t()], pos_integer()) :: {[Snapshot.t()], [Snapshot.t()]}
  def keep(snapshots, count \\ @kept),
    do: snapshots |> Enum.sort_by(& &1.taken_at, {:desc, DateTime}) |> Enum.split(count)

  @doc "Deletes a snapshot's copy."
  @spec delete!(paths(), Snapshot.t()) :: :ok
  def delete!(paths, %Snapshot{id: id}) do
    File.rm(snapshot_path(paths, id))
    :ok
  end

  @doc "How much host space a disk takes now, in bytes: what the VM has written, not its size."
  @spec used(Path.t()) :: non_neg_integer()
  def used(path) do
    case System.cmd("stat", ["--format=%b %B", path], stderr_to_stdout: true) do
      {output, 0} ->
        [blocks, block_size] = output |> String.split() |> Enum.map(&String.to_integer/1)
        blocks * block_size

      _missing ->
        0
    end
  end

  defp snapshot_path(paths, id), do: Path.join(paths.snapshots, id <> ".img")

  @doc """
  Whether the copy `snapshot` stands for is there. Copies of Home recorded
  before Home was a disk (2026-11-13) have none.
  """
  @spec snapshot?(paths(), Snapshot.t()) :: boolean()
  def snapshot?(paths, %Snapshot{id: id}), do: File.regular?(snapshot_path(paths, id))

  # A sparse file, then a file system in it, owned by root as the VM sees it.
  defp make!(path, bytes) do
    run!("truncate", ["--size=#{bytes}", path])
    run!(tool!("mkfs.ext4"), ["-q", "-F", "-E", "root_owner=0:0", "-L", label(path), path])
    File.chmod!(path, 0o600)
    :ok
  end

  # The file first, then the file system into the new room. `resize2fs`
  # wants the file system checked first.
  defp grow!(path, bytes) do
    run!("truncate", ["--size=#{bytes}", path])

    case System.cmd(tool!("e2fsck"), ["-f", "-p", path], stderr_to_stdout: true) do
      # 0 is clean, 1 is "errors corrected": both leave a sound file system.
      {_, status} when status in [0, 1] -> :ok
      {output, status} -> raise "checking #{path} failed (#{status}): #{String.trim(output)}"
    end

    run!(tool!("resize2fs"), [path])
    :ok
  end

  defp label(path), do: "mdt-" <> Path.basename(path, ".img")

  # A whole-file copy that shares blocks where the file system can, and
  # keeps holes as holes where it can't.
  defp copy!(source, destination) do
    partial = destination <> ".part"
    File.rm(partial)
    run!("cp", ["--reflink=auto", "--sparse=always", source, partial])
    File.chmod!(partial, 0o600)
    File.rename!(partial, destination)
    :ok
  end

  defp run!(command, args) do
    case System.cmd(command, args, stderr_to_stdout: true) do
      {_, 0} ->
        :ok

      {output, status} ->
        raise "#{Path.basename(command)} failed (#{status}): #{String.trim(output)}"
    end
  end

  defp tool!(name), do: tool(name) || raise("#{name} isn't installed (package e2fsprogs)")

  # The e2fsprogs tools sit in /usr/sbin, which isn't on every user's PATH.
  defp tool(name) do
    System.find_executable(name) ||
      Enum.find(["/usr/sbin/#{name}", "/sbin/#{name}"], &File.regular?/1)
  end

  defp gib, do: 1024 * 1024 * 1024
  defp unique, do: :crypto.strong_rand_bytes(3) |> Base.encode16(case: :lower)
end
