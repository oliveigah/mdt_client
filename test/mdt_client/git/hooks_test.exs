defmodule MDTClient.Git.HooksTest do
  use ExUnit.Case, async: true

  import MDTClient.GitHelpers

  alias MDTClient.Git.Core
  alias MDTClient.Git.Error

  setup :initialized_repository

  test "a refusing pre-commit hook blocks a commit unless hooks are skipped", context do
    %{path: path, repository: repository, initial_commit: initial} = context
    failing_hook!(path, "pre-commit")
    File.write!(Path.join(path, "staged.txt"), "staged\n")
    git!(path, ["add", "staged.txt"])

    assert {:error, %Error{output: output}} = Core.commit(repository, "checked")
    assert output =~ "pre-commit hook refused"
    assert git!(path, ["rev-parse", "HEAD"]) == initial

    assert {:ok, _} = Core.commit(repository, "unchecked", no_verify: true)
    assert git!(path, ["log", "-1", "--format=%s"]) == "unchecked"
  end

  test "skipping hooks also skips commit-msg", context do
    %{path: path, repository: repository} = context
    failing_hook!(path, "commit-msg")

    assert {:error, %Error{}} = Core.commit(repository, "checked", allow_empty: true)

    assert {:ok, _} =
             Core.commit(repository, "unchecked", allow_empty: true, no_verify: true)

    assert git!(path, ["log", "-1", "--format=%s"]) == "unchecked"
  end

  test "a refusing pre-push hook blocks a push unless hooks are skipped", context do
    %{base: base, path: path, repository: repository, initial_commit: initial} = context
    origin!(base, path)
    local = commit_file(path, "local.txt", "local\n", "local")
    failing_hook!(path, "pre-push")
    remote = Path.join(base, "remote.git")

    assert {:error, %Error{output: output}} = Core.push(repository)
    assert output =~ "pre-push hook refused"
    assert git!(remote, ["rev-parse", "main"]) == initial

    assert {:ok, _} = Core.push(repository, no_verify: true)
    assert git!(remote, ["rev-parse", "main"]) == local
  end

  test "no_verify must be a boolean", context do
    %{repository: repository} = context

    assert {:error, %Error{kind: :invalid_argument}} =
             Core.commit(repository, "message", no_verify: "yes")

    assert {:error, %Error{kind: :invalid_argument}} = Core.push(repository, no_verify: 1)
  end
end
