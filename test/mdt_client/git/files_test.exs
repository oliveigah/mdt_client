defmodule MDTClient.Git.FilesTest do
  use ExUnit.Case, async: true

  import MDTClient.GitHelpers

  alias MDTClient.Git.Core
  alias MDTClient.Git.FileChange
  alias MDTClient.Git.FileDiff
  alias MDTClient.Git.Files

  setup :initialized_repository

  defp change(changes, path), do: Enum.find(changes, &(&1.path == path))

  test "a clean worktree has no changes", %{repository: repository} do
    assert {:ok, []} = Files.status(repository)
  end

  test "separates the index side from the working tree side", context do
    %{path: path, repository: repository} = context

    File.write!(Path.join(path, "staged.txt"), "staged\n")
    File.write!(Path.join(path, "README.md"), "changed\n")
    git!(path, ["add", "--", "staged.txt"])

    assert {:ok, changes} = Files.status(repository)

    assert %FileChange{staged: :added, unstaged: nil, untracked?: false} =
             change(changes, "staged.txt")

    assert %FileChange{staged: nil, unstaged: :modified} = change(changes, "README.md")

    assert Enum.map(changes, & &1.path) == ["README.md", "staged.txt"]
  end

  test "reports a path changed on both sides", context do
    %{path: path, repository: repository} = context

    File.write!(Path.join(path, "both.txt"), "one\n")
    git!(path, ["add", "--", "both.txt"])
    File.write!(Path.join(path, "both.txt"), "two\n")

    assert {:ok, changes} = Files.status(repository)
    assert %FileChange{staged: :added, unstaged: :modified} = change(changes, "both.txt")
  end

  test "reports deletions, untracked files and nested untracked files", context do
    %{path: path, repository: repository} = context

    File.rm!(Path.join(path, "README.md"))
    File.write!(Path.join(path, "loose.txt"), "loose\n")
    File.mkdir_p!(Path.join(path, "nested/deeper"))
    File.write!(Path.join(path, "nested/deeper/file.txt"), "deep\n")

    assert {:ok, changes} = Files.status(repository)

    assert %FileChange{unstaged: :deleted} = change(changes, "README.md")
    assert %FileChange{unstaged: :untracked, untracked?: true} = change(changes, "loose.txt")

    assert %FileChange{untracked?: true} = change(changes, "nested/deeper/file.txt")
  end

  test "reports a staged deletion", context do
    %{path: path, repository: repository} = context

    git!(path, ["rm", "--", "README.md"])

    assert {:ok, changes} = Files.status(repository)
    assert %FileChange{staged: :deleted, unstaged: nil} = change(changes, "README.md")
  end

  test "keeps file names containing spaces, quotes and newlines intact", context do
    %{path: path, repository: repository} = context

    awkward = "a file 'with' \"quotes\" and\na newline.txt"
    File.write!(Path.join(path, awkward), "awkward\n")
    File.write!(Path.join(path, "plain name.txt"), "plain\n")
    git!(path, ["add", "--", "plain name.txt"])

    assert {:ok, changes} = Files.status(repository)

    assert %FileChange{untracked?: true} = change(changes, awkward)
    assert %FileChange{staged: :added} = change(changes, "plain name.txt")
  end

  test "reports renames with the original path", context do
    %{path: path, repository: repository} = context

    File.write!(Path.join(path, "original name.txt"), String.duplicate("content\n", 20))
    git!(path, ["add", "-A"])
    git!(path, ["commit", "-m", "add file to rename"])

    git!(path, ["mv", "original name.txt", "renamed name.txt"])

    assert {:ok, changes} = Files.status(repository)

    assert %FileChange{staged: :renamed, original_path: "original name.txt"} =
             change(changes, "renamed name.txt")
  end

  test "flags conflicted paths", context do
    %{path: path, repository: repository} = context

    git!(path, ["checkout", "-b", "side"])
    commit_file(path, "conflict.txt", "side\n", "side change")
    git!(path, ["checkout", "main"])
    commit_file(path, "conflict.txt", "main\n", "main change")

    assert {:error, _conflict} = Core.merge(repository, "side")
    assert {:ok, changes} = Files.status(repository)

    assert %FileChange{conflicted?: true, unstaged: :conflicted} = change(changes, "conflict.txt")
  end

  test "sees the working tree of a repository with no commits", %{base: base} do
    fresh = Path.join(base, "fresh")
    File.mkdir_p!(fresh)
    git!(fresh, ["init", "--initial-branch=main"])
    File.write!(Path.join(fresh, "first.txt"), "first\n")

    {:ok, repository} = Core.open(fresh)

    assert {:ok, [%FileChange{path: "first.txt", untracked?: true}]} = Files.status(repository)
  end

  test "ignores files excluded by gitignore", context do
    %{path: path, repository: repository} = context

    File.write!(Path.join(path, ".gitignore"), "ignored.txt\n")
    File.write!(Path.join(path, "ignored.txt"), "ignored\n")
    git!(path, ["add", "--", ".gitignore"])
    git!(path, ["commit", "-m", "ignore"])

    assert {:ok, changes} = Files.status(repository)
    assert changes == []
  end

  test "the staged and unstaged predicates split the list", context do
    %{path: path, repository: repository} = context

    File.write!(Path.join(path, "staged.txt"), "staged\n")
    git!(path, ["add", "--", "staged.txt"])
    File.write!(Path.join(path, "README.md"), "changed\n")

    assert {:ok, changes} = Files.status(repository)

    assert Enum.map(Enum.filter(changes, &FileChange.staged?/1), & &1.path) == ["staged.txt"]
    assert Enum.map(Enum.filter(changes, &FileChange.unstaged?/1), & &1.path) == ["README.md"]
  end

  describe "diff/3" do
    setup %{path: path} do
      File.write!(Path.join(path, "counted.txt"), Enum.map_join(1..10, "", &"line #{&1}\n"))
      git!(path, ["add", "-A"])
      git!(path, ["commit", "-m", "add counted"])
      :ok
    end

    test "reads the working tree against the index", context do
      %{path: path, repository: repository} = context
      File.write!(Path.join(path, "counted.txt"), "line 1\nCHANGED\nline 3\n")

      assert {:ok, %FileDiff{side: :unstaged, binary?: false} = diff} =
               Files.diff(repository, "counted.txt")

      assert %{added: 1, removed: 8} = FileDiff.counts(diff)

      lines = Enum.flat_map(diff.hunks, & &1.lines)
      assert %{kind: :context, text: "line 1", old_line: 1, new_line: 1} = hd(lines)
      assert Enum.any?(lines, &(&1.kind == :added and &1.text == "CHANGED" and &1.new_line == 2))
      assert Enum.any?(lines, &(&1.kind == :removed and &1.text == "line 2" and &1.old_line == 2))
    end

    test "reads the index against HEAD", context do
      %{path: path, repository: repository} = context
      File.write!(Path.join(path, "counted.txt"), "staged only\n")
      git!(path, ["add", "--", "counted.txt"])

      assert {:ok, staged} = Files.diff(repository, "counted.txt", side: :staged)
      assert %{added: 1, removed: 10} = FileDiff.counts(staged)

      # The working tree now matches the index, so that side has nothing to show.
      assert {:ok, %FileDiff{hunks: []}} = Files.diff(repository, "counted.txt")
    end

    test "reads an untracked file as entirely added", context do
      %{path: path, repository: repository} = context
      File.write!(Path.join(path, "fresh file.txt"), "one\ntwo\n")

      assert {:ok, diff} = Files.diff(repository, "fresh file.txt", untracked: true)
      assert %{added: 2, removed: 0} = FileDiff.counts(diff)
      assert Enum.map(Enum.flat_map(diff.hunks, & &1.lines), & &1.text) == ["one", "two"]

      # Nothing about it is staged yet.
      assert {:ok, %FileDiff{hunks: []}} =
               Files.diff(repository, "fresh file.txt", side: :staged, untracked: true)
    end

    test "carries the hunk heading and starting lines", context do
      %{path: path, repository: repository} = context

      File.write!(
        Path.join(path, "counted.txt"),
        Enum.map_join(1..10, "", fn
          8 -> "line 8 changed\n"
          line -> "line #{line}\n"
        end)
      )

      assert {:ok, diff} = Files.diff(repository, "counted.txt")
      assert [hunk] = diff.hunks
      assert hunk.header =~ "@@"
      assert hunk.old_start > 1
      assert hunk.new_start > 1
    end

    test "flags a binary file instead of rendering it", context do
      %{path: path, repository: repository} = context
      File.write!(Path.join(path, "blob.bin"), <<0, 1, 2, 0, 255>>)
      git!(path, ["add", "-A"])
      git!(path, ["commit", "-m", "add blob"])
      File.write!(Path.join(path, "blob.bin"), <<0, 9, 9, 0, 1>>)

      assert {:ok, %FileDiff{binary?: true, hunks: []}} = Files.diff(repository, "blob.bin")
    end

    test "stops at the line budget and says so", context do
      %{path: path, repository: repository} = context
      File.write!(Path.join(path, "counted.txt"), Enum.map_join(1..400, "", &"new #{&1}\n"))

      assert {:ok, %FileDiff{truncated?: true} = diff} =
               Files.diff(repository, "counted.txt", lines: 5)

      assert Enum.sum(Enum.map(diff.hunks, &length(&1.lines))) == 5

      assert {:ok, %FileDiff{truncated?: false}} =
               Files.diff(repository, "counted.txt", lines: 5_000)
    end

    test "refuses paths outside the repository and bad options", %{repository: repository} do
      assert {:error, %{kind: :invalid_argument}} = Files.diff(repository, "../escape.txt")
      assert {:error, %{kind: :invalid_argument}} = Files.diff(repository, "")
      assert {:error, %{kind: :invalid_argument}} = Files.diff(repository, "a.txt", side: :both)
      assert {:error, %{kind: :invalid_argument}} = Files.diff(repository, "a.txt", lines: 0)
    end
  end
end
