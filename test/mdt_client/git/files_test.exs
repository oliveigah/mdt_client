defmodule MDTClient.Git.FilesTest do
  use ExUnit.Case, async: true

  import MDTClient.GitHelpers

  alias MDTClient.Git.Core
  alias MDTClient.Git.FileChange
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
end
