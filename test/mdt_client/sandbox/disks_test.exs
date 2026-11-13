defmodule MDTClient.Sandbox.DisksTest do
  use ExUnit.Case, async: true

  alias MDTClient.Sandbox.{Disks, Snapshot}

  @sizes %{home: 1, cache: 1, work: 2}
  @gib 1024 * 1024 * 1024

  setup do
    dir = Path.join(System.tmp_dir!(), "disks-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    %{paths: Disks.paths(dir)}
  end

  # What `file` says is in the image, without mounting it.
  defp kind(path), do: "file" |> System.cmd(["--brief", path]) |> elem(0)

  defp blocks(path) do
    {text, 0} = System.cmd("/usr/sbin/dumpe2fs", ["-h", path], stderr_to_stdout: true)
    [_, count] = Regex.run(~r/^Block count:\s+(\d+)/m, text)
    [_, size] = Regex.run(~r/^Block size:\s+(\d+)/m, text)
    String.to_integer(count) * String.to_integer(size)
  end

  test "the tools that make disks are on this machine" do
    assert Disks.missing_tools() == []
  end

  test "each disk is a sparse ext4 image of its size, yours only", %{paths: paths} do
    assert :ok = Disks.ensure!(paths, @sizes)

    for name <- Disks.names() do
      path = Map.fetch!(paths, name)
      assert File.stat!(path).size == @sizes[name] * @gib
      assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
      assert kind(path) =~ "ext4 filesystem"
      assert kind(path) =~ "mdt-#{name}"
      # Sparse: megabytes on this machine, not gigabytes.
      assert Disks.used(path) < 64 * 1024 * 1024
    end

    assert Disks.mount_point(:home) == "/root"
    assert Disks.mount_point(:work) == "/work"
  end

  test "a disk that exists is left as it is, and grown when its size grew", %{paths: paths} do
    :ok = Disks.ensure!(paths, @sizes)
    before = File.read!(paths.cache) |> :erlang.md5()

    :ok = Disks.ensure!(paths, %{@sizes | home: 2})

    assert File.stat!(paths.home).size == 2 * @gib
    assert blocks(paths.home) == 2 * @gib
    assert File.read!(paths.cache) |> :erlang.md5() == before

    # Never smaller.
    :ok = Disks.ensure!(paths, %{@sizes | home: 1})
    assert File.stat!(paths.home).size == 2 * @gib
  end

  test "Home is copied whole, put back, and emptied", %{paths: paths} do
    :ok = Disks.ensure!(paths, @sizes)
    # Stands in for what the VM wrote: bytes past the file system's start.
    {:ok, file} = :file.open(paths.home, [:read, :write, :binary])
    :ok = :file.pwrite(file, 512 * 1024 * 1024, "the vm was here")
    :ok = :file.close(file)
    written = File.read!(paths.home) |> :erlang.md5()

    now = ~U[2026-11-13 12:00:00Z]

    assert %Snapshot{id: id, tag: "2026-11-13.1", taken_at: ^now} =
             snapshot = Disks.snapshot!(paths, "2026-11-13.1", now)

    assert id =~ ~r/^20261113T120000-[0-9a-f]{6}$/

    :ok = Disks.empty!(paths.home)
    assert File.stat!(paths.home).size == @gib
    refute File.read!(paths.home) |> :erlang.md5() == written
    assert kind(paths.home) =~ "ext4 filesystem"

    :ok = Disks.restore!(paths, snapshot)
    assert File.read!(paths.home) |> :erlang.md5() == written

    :ok = Disks.delete!(paths, snapshot)
    assert_raise RuntimeError, ~r/is gone/, fn -> Disks.restore!(paths, snapshot) end
  end

  test "the newest three snapshots are kept" do
    snapshots =
      for day <- 1..5 do
        {:ok, at, 0} = DateTime.from_iso8601("2026-11-0#{day}T00:00:00Z")
        %Snapshot{id: "s#{day}", tag: nil, taken_at: at}
      end

    assert {kept, removed} = Disks.keep(Enum.shuffle(snapshots))
    assert Enum.map(kept, & &1.id) == ["s5", "s4", "s3"]
    assert Enum.map(removed, & &1.id) == ["s2", "s1"]
  end
end
