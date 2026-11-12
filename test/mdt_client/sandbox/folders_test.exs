defmodule MDTClient.Sandbox.FoldersTest do
  use ExUnit.Case, async: true

  alias MDTClient.Sandbox.{Folders, Snapshot}

  setup do
    dir = Path.join(System.tmp_dir!(), "folders-test-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    paths = Folders.paths(dir)
    Folders.ensure!(paths)
    %{paths: paths}
  end

  test "a new Home counts as empty, mount point and all", %{paths: paths} do
    assert File.dir?(Path.join(paths.home, ".optmem"))
    assert Folders.empty?(paths.home)
    File.write!(Path.join(paths.home, ".bash_history"), "ls\n")
    refute Folders.empty?(paths.home)
  end

  test "a snapshot survives emptying Home and brings it back", %{paths: paths} do
    File.mkdir_p!(Path.join(paths.home, ".codex"))
    File.write!(Path.join(paths.home, ".codex/auth.json"), "{}")
    File.ln_s!("/nowhere", Path.join(paths.home, "link"))

    snapshot = Folders.snapshot!(paths, "2026-11-12.1", ~U[2026-11-12 12:00:00Z])
    assert snapshot.tag == "2026-11-12.1"

    Folders.empty!(paths.home)
    assert File.ls!(paths.home) == []

    Folders.restore!(paths, snapshot)
    assert File.read!(Path.join(paths.home, ".codex/auth.json")) == "{}"
    # Links the VM made are copied as links, never followed.
    assert {:ok, "/nowhere"} = File.read_link(Path.join(paths.home, "link"))
    assert File.dir?(Path.join(paths.snapshots, snapshot.id))
  end

  test "three snapshots are kept, newest first", %{paths: paths} do
    snapshots =
      for n <- 1..4,
          do: %Snapshot{id: "s#{n}", taken_at: DateTime.add(~U[2026-11-12 12:00:00Z], n, :hour)}

    {kept, removed} = Folders.keep(snapshots)
    assert Enum.map(kept, & &1.id) == ["s4", "s3", "s2"]
    assert Enum.map(removed, & &1.id) == ["s1"]
    _ = paths
  end
end
