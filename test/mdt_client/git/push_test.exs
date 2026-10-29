defmodule MDTClient.Git.PushTest do
  use ExUnit.Case, async: true

  import MDTClient.GitHelpers

  alias MDTClient.Git.Core
  alias MDTClient.Git.Error

  setup :initialized_repository

  test "an explicit destination pushes only the selected branch and sets its upstream", context do
    %{base: base, path: path, repository: repository, initial_commit: initial} = context
    origin!(base, path)
    git!(path, ["branch", "other"])

    assert {:ok, _} =
             Core.push(repository,
               remote: "origin",
               branch: "main",
               destination: "published",
               set_upstream: true
             )

    assert git!(path, ["rev-parse", "main@{upstream}"]) == initial
    assert git!(path, ["config", "branch.main.merge"]) == "refs/heads/published"

    assert {_, 2} =
             System.cmd("git", [
               "-C",
               path,
               "ls-remote",
               "--exit-code",
               "origin",
               "refs/heads/other"
             ])
  end

  test "a pinned lease refuses remote changes even after a fetch; force can overwrite", context do
    %{base: base, path: path, repository: repository, initial_commit: initial} = context
    elsewhere = origin!(base, path)
    local = commit_file(path, "local.txt", "local\n", "local")
    remote = push_commit!(elsewhere, "main", "remote.txt", "remote")
    git!(path, ["fetch", "origin"])

    assert {:error, %Error{output: output}} =
             Core.push(repository,
               remote: "origin",
               branch: "main",
               destination: "main",
               force_with_lease: {"main", initial}
             )

    assert output =~ "[rejected] (stale info)"
    assert git!(Path.join(base, "remote.git"), ["rev-parse", "main"]) == remote

    assert {:ok, _} =
             Core.push(repository,
               remote: "origin",
               branch: "main",
               destination: "main",
               force: true
             )

    assert git!(Path.join(base, "remote.git"), ["rev-parse", "main"]) == local
  end

  test "a named branch can use its configured default remote", context do
    %{base: base, path: path, repository: repository} = context
    origin!(base, path)
    local = commit_file(path, "local.txt", "local\n", "local")

    assert {:ok, _} = Core.push(repository, branch: "main")
    assert git!(Path.join(base, "remote.git"), ["rev-parse", "main"]) == local
  end

  test "invalid force options and destinations fail before pushing", context do
    %{base: base, path: path, repository: repository, initial_commit: initial} = context
    origin!(base, path)
    commit_file(path, "local.txt", "local\n", "local")

    for opts <- [
          [force: "yes"],
          [force: true, force_with_lease: true],
          [force_with_lease: {"main", "invalid"}],
          [force_with_lease: {"--all", initial}],
          [branch: "main", destination: "--all"]
        ] do
      assert {:error, %Error{kind: :invalid_argument}} = Core.push(repository, opts)
    end

    assert git!(Path.join(base, "remote.git"), ["rev-parse", "main"]) == initial
  end
end
