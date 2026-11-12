defmodule MDTClient.Sandbox.MemoryTest do
  use ExUnit.Case, async: true

  alias MDTClient.Sandbox.Memory

  setup do
    root = Path.join(System.tmp_dir!(), "memory-test-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    %{optmem: Path.join(root, "optmem"), source: Path.join(root, "mine")}
  end

  defp record(id, text), do: String.pad_trailing("##{id} 2026-11-12 #{text}", 319) <> "\n"

  defp write_log(dir, records) do
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "LOG.txt"), Enum.join(records))
  end

  test "entries are complete records only, from a position on", %{optmem: optmem} do
    write_log(Path.join(optmem, "memory"), [
      record(0, "[general] first"),
      record(1, "[vm] second"),
      "#2 2026-11-12 half writ"
    ])

    assert Memory.count(optmem) == 2

    assert [%{index: 1, id: "1", date: "2026-11-12", text: "[vm] second"}] =
             Memory.entries(optmem, 1)

    assert Memory.entries(Path.join(optmem, "none"), 0) == []
  end

  test "seeding copies the shared files and moves the VM's memory aside", %{
    optmem: optmem,
    source: source
  } do
    write_log(source, [record(0, "mine"), record(1, "mine too")])
    File.write!(Path.join(source, "config"), "# sizes\n")
    File.write!(Path.join(source, ".lock"), "")
    File.write!(Path.join(source, "secret-notes.txt"), "not shared")
    write_log(Path.join(optmem, "memory"), [record(0, "the VM's own")])

    assert Memory.seed!(optmem, source) == 2
    assert Memory.entries(optmem, 0) |> Enum.map(& &1.text) == ["mine", "mine too"]
    assert File.exists?(Path.join([optmem, "memory", "config"]))
    refute File.exists?(Path.join([optmem, "memory", "secret-notes.txt"]))
    assert [aside] = Path.wildcard(Path.join(optmem, "memory.before-*"))
    assert File.read!(Path.join(aside, "LOG.txt")) =~ "the VM's own"
  end

  test "seeding refuses a folder with no memory", %{optmem: optmem, source: source} do
    File.mkdir_p!(source)
    assert_raise RuntimeError, ~r/no OptMem memory/, fn -> Memory.seed!(optmem, source) end
  end
end
