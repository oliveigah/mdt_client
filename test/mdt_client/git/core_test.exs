defmodule MDTClient.Git.CoreTest do
  use ExUnit.Case, async: true

  import MDTClient.GitHelpers

  alias MDTClient.Git.CommandResult
  alias MDTClient.Git.Core
  alias MDTClient.Git.Error
  alias MDTClient.Git.Repository
  alias MDTClient.Git.Stash
  alias MDTClient.Git.Tag

  setup :initialized_repository

  test "opens a nested folder as a tab-scoped repository handle", %{path: path} do
    nested = Path.join(path, "one/two")
    File.mkdir_p!(nested)

    assert {:ok, %Repository{} = repository} = Core.open(nested)

    assert repository.path == path
    assert repository.git_dir == Path.join(path, ".git")
    assert repository.common_dir == Path.join(path, ".git")
    assert repository.ssh_key == nil

    {private_key, public_key} = ssh_key_pair(path)

    assert {:ok, updated} = Core.with_ssh_keys(repository, private_key, public_key)
    assert updated.ssh_key.private_key == private_key
    assert updated.ssh_key.public_key == public_key
    assert repository.ssh_key == nil

    assert {:ok, cleared} = Core.without_ssh_keys(updated)
    assert cleared.ssh_key == nil
  end

  test "validates that the selected SSH keys form a pair", %{base: base, repository: repository} do
    {first_private, _first_public} = ssh_key_pair(base, "first")
    {_second_private, second_public} = ssh_key_pair(base, "second")

    assert {:error, %Error{kind: :invalid_argument, message: message}} =
             Core.with_ssh_keys(repository, first_private, second_public)

    assert message =~ "do not form a pair"

    assert {:error, %Error{kind: :invalid_argument, message: "Private key path cannot be empty"}} =
             Core.with_ssh_keys(repository, "", second_public)
  end

  test "lists remotes and converts an HTTPS URL to SSH", %{path: path, repository: repository} do
    git!(path, ["remote", "add", "origin", "https://github.com/example/project.git"])

    git!(path, [
      "remote",
      "set-url",
      "--push",
      "origin",
      "https://github.com/example/project.git"
    ])

    assert {:ok, [remote]} = Core.list_remotes(repository)
    assert remote.name == "origin"
    assert remote.kind == :https
    assert remote.push_url == "https://github.com/example/project.git"
    assert remote.ssh_url == "git@github.com:example/project.git"

    assert {:ok, %CommandResult{action: :set_remote_url}} =
             Core.use_ssh_remote(repository, "origin")

    assert git!(path, ["remote", "get-url", "origin"]) == "git@github.com:example/project.git"

    assert git!(path, ["remote", "get-url", "--push", "origin"]) ==
             "git@github.com:example/project.git"

    assert {:ok, [%{kind: :ssh, ssh_url: nil}]} = Core.list_remotes(repository)
  end

  test "rejects folders that are not worktrees", %{base: base} do
    outside = Path.join(base, "outside")
    File.mkdir_p!(outside)

    assert {:error, %Error{kind: :invalid_repository}} = Core.open(outside)
    assert {:error, %Error{kind: :invalid_repository}} = Core.open(Path.join(base, "missing"))
  end

  test "loads graph metadata, tracking state, and branch labels", context do
    %{base: base, path: path, repository: repository, initial_commit: initial_commit} = context

    assert {:ok, %CommandResult{}} = Core.create_branch(repository, "feature")
    assert {:ok, %CommandResult{}} = Core.checkout_branch(repository, "feature")
    feature_commit = commit_file(path, "feature.txt", "feature\n", "feature work")
    assert {:ok, %CommandResult{}} = Core.checkout_branch(repository, "main")

    remote = Path.join(base, "remote.git")
    File.mkdir_p!(remote)
    git!(remote, ["init", "--bare"])
    git!(path, ["remote", "add", "origin", remote])
    git!(path, ["push", "-u", "origin", "main"])
    git!(path, ["push", "origin", "feature"])

    assert {:ok, snapshot} = Core.snapshot(repository)
    assert snapshot.head == initial_commit
    assert snapshot.current_branch == "main"
    refute snapshot.detached?
    assert snapshot.operation == nil

    assert Enum.any?(snapshot.branches, &(&1.name == "main" and &1.current?))

    assert Enum.any?(
             snapshot.branches,
             &(&1.name == "origin/feature" and &1.kind == :remote)
           )

    commit = Enum.find(snapshot.commits, &(&1.id == feature_commit))
    assert commit.summary == "feature work"
    assert commit.author_name == "MDT Test"
    assert commit.author_email == "mdt@example.test"
    assert %DateTime{} = commit.authored_at
    assert commit.signature_status == :no_signature
    assert Enum.map(commit.labels, & &1.name) |> Enum.sort() == ["feature", "origin/feature"]

    assert {:ok, inspected} = Core.get_commit(repository, feature_commit)
    assert inspected == commit
  end

  test "fingerprints stay stable until repository state changes", %{
    path: path,
    repository: repository
  } do
    assert {:ok, initial} = Core.fingerprint(repository)
    assert {:ok, ^initial} = Core.fingerprint(repository)

    File.write!(Path.join(path, "outside.txt"), "outside\n")
    assert {:ok, worktree_changed} = Core.fingerprint(repository)
    refute worktree_changed == initial

    git!(path, ["add", "outside.txt"])
    assert {:ok, index_changed} = Core.fingerprint(repository)
    refute index_changed == worktree_changed

    git!(path, ["remote", "add", "origin", "https://example.test/project.git"])
    assert {:ok, config_changed} = Core.fingerprint(repository)
    refute config_changed == index_changed
  end

  test "creates, checks out, renames, and deletes local branches", %{repository: repository} do
    assert {:ok, %CommandResult{action: :create_branch}} =
             Core.create_branch(repository, "topic")

    assert {:ok, %CommandResult{action: :checkout_branch}} =
             Core.checkout_branch(repository, "topic")

    assert {:ok, %CommandResult{action: :rename_branch}} =
             Core.rename_branch(repository, "topic", "renamed")

    assert {:ok, snapshot} = Core.snapshot(repository)
    assert snapshot.current_branch == "renamed"
    assert Enum.any?(snapshot.branches, &(&1.name == "renamed" and &1.current?))

    assert {:ok, _result} = Core.checkout_branch(repository, "main")

    assert {:ok, %CommandResult{action: :delete_branch}} =
             Core.delete_branch(repository, "renamed")

    assert {:ok, branches} = Core.list_branches(repository)
    refute Enum.any?(branches, &(&1.name == "renamed"))
  end

  test "checks out a remote branch as a local tracking branch", context do
    %{base: base, path: path, repository: repository} = context

    git!(path, ["branch", "server-topic"])
    remote = Path.join(base, "remote.git")
    File.mkdir_p!(remote)
    git!(remote, ["init", "--bare"])
    git!(path, ["remote", "add", "origin", remote])
    git!(path, ["push", "origin", "server-topic"])
    git!(path, ["branch", "-D", "server-topic"])

    assert {:ok, %CommandResult{action: :checkout_remote_branch}} =
             Core.checkout_remote_branch(repository, "origin/server-topic", as: "local-topic")

    assert {:ok, snapshot} = Core.snapshot(repository)
    assert snapshot.current_branch == "local-topic"

    branch = Enum.find(snapshot.branches, &(&1.name == "local-topic"))
    assert branch.upstream == "origin/server-topic"
  end

  test "merges, cherry-picks, reverts, and resets commits", context do
    %{path: path, repository: repository, initial_commit: initial_commit} = context

    assert {:ok, _result} = Core.create_branch(repository, "feature")
    assert {:ok, _result} = Core.checkout_branch(repository, "feature")
    feature_commit = commit_file(path, "feature.txt", "one\n", "feature commit")
    assert {:ok, _result} = Core.checkout_branch(repository, "main")
    main_commit = commit_file(path, "main.txt", "main\n", "main commit")

    assert {:ok, %CommandResult{action: :merge}} =
             Core.merge(repository, "feature", no_ff: true, message: "merge feature")

    merge_commit = git!(path, ["rev-parse", "HEAD"])
    assert length(String.split(git!(path, ["show", "-s", "--format=%P", merge_commit]))) == 2

    assert {:ok, %CommandResult{action: :reset}} = Core.reset(repository, main_commit, :hard)
    refute File.exists?(Path.join(path, "feature.txt"))

    assert {:ok, %CommandResult{action: :cherry_pick}} =
             Core.cherry_pick(repository, feature_commit)

    assert File.read!(Path.join(path, "feature.txt")) == "one\n"

    assert {:ok, %CommandResult{action: :revert}} = Core.revert(repository, "HEAD")
    refute File.exists?(Path.join(path, "feature.txt"))

    assert {:ok, %CommandResult{action: :reset}} = Core.reset(repository, initial_commit, :soft)
    assert git!(path, ["rev-parse", "HEAD"]) == initial_commit
    assert git!(path, ["diff", "--cached", "--name-only"]) == "main.txt"

    assert {:ok, %CommandResult{action: :reset}} = Core.reset(repository, initial_commit, :hard)
    assert git!(path, ["status", "--porcelain"]) == ""
  end

  test "rebases the checked-out branch", %{path: path, repository: repository} do
    assert {:ok, _result} = Core.create_branch(repository, "topic")
    main_commit = commit_file(path, "main.txt", "main\n", "main work")
    assert {:ok, _result} = Core.checkout_branch(repository, "topic")
    old_topic = commit_file(path, "topic.txt", "topic\n", "topic work")

    assert {:ok, %CommandResult{action: :rebase}} = Core.rebase(repository, "main")

    new_topic = git!(path, ["rev-parse", "HEAD"])
    refute new_topic == old_topic
    assert git!(path, ["rev-parse", "HEAD^"]) == main_commit
  end

  test "edits HEAD without including staged changes", %{path: path, repository: repository} do
    _second = commit_file(path, "second.txt", "second\n", "old subject")
    File.write!(Path.join(path, "staged.txt"), "keep staged\n")
    git!(path, ["add", "staged.txt"])

    assert {:ok, %CommandResult{action: :edit_commit_message}} =
             Core.edit_commit_message(repository, "HEAD", "new subject")

    assert git!(path, ["show", "-s", "--format=%s", "HEAD"]) == "new subject"
    assert git!(path, ["diff", "--cached", "--name-only"]) == "staged.txt"
    refute git!(path, ["show", "--format=", "--name-only", "HEAD"]) =~ "staged.txt"
  end

  test "edits an older commit and rebases its descendants", context do
    %{path: path, repository: repository, initial_commit: initial_commit} = context

    second = commit_file(path, "second.txt", "second\n", "second subject")
    old_head = commit_file(path, "third.txt", "third\n", "third subject")

    assert {:ok, %CommandResult{action: :edit_commit_message}} =
             Core.edit_commit_message(repository, second, "renamed second")

    new_head = git!(path, ["rev-parse", "HEAD"])
    refute new_head == old_head
    assert git!(path, ["show", "-s", "--format=%s", "HEAD"]) == "third subject"
    assert git!(path, ["show", "-s", "--format=%s", "HEAD^"]) == "renamed second"
    assert git!(path, ["rev-parse", "HEAD^^"]) == initial_commit
    # The branch moves with the rewrite instead of staying on the old commits.
    assert git!(path, ["symbolic-ref", "--short", "HEAD"]) == "main"
    assert git!(path, ["rev-parse", "main"]) == new_head
  end

  describe "squash/3" do
    test "folds consecutive commits into one and replays what follows", context do
      %{path: path, repository: repository, initial_commit: initial} = context
      second = commit_file(path, "second.txt", "second\n", "second subject")
      third = commit_file(path, "third.txt", "third\n", "third subject")
      commit_file(path, "fourth.txt", "fourth\n", "fourth subject")

      assert {:ok, %CommandResult{action: :squash}} =
               Core.squash(repository, [third, second], "second and third")

      assert git!(path, ["symbolic-ref", "--short", "HEAD"]) == "main"

      assert git!(path, ["log", "--format=%s", "main"]) ==
               "fourth subject\nsecond and third\ninitial commit"

      assert git!(path, ["rev-parse", "HEAD~2"]) == initial
      assert git!(path, ["show", "--format=", "--name-only", "HEAD~1"]) == "second.txt\nthird.txt"
      assert git!(path, ["status", "--porcelain"]) == ""
    end

    test "can take HEAD in, keeping the oldest commit's author", context do
      %{path: path, repository: repository, initial_commit: initial} = context
      git!(path, ["-c", "user.name=First Author", "commit", "--allow-empty", "-m", "first"])
      commit_file(path, "second.txt", "second\n", "second")

      assert {:ok, _result} = Core.squash(repository, ["HEAD", "HEAD~1"], "both")

      assert git!(path, ["log", "--format=%s", "main"]) == "both\ninitial commit"
      assert git!(path, ["show", "-s", "--format=%an", "HEAD"]) == "First Author"
      assert git!(path, ["rev-parse", "HEAD~1"]) == initial
    end

    test "refuses what it cannot fold safely", context do
      %{path: path, repository: repository, initial_commit: initial} = context
      second = commit_file(path, "second.txt", "second\n", "second")
      third = commit_file(path, "third.txt", "third\n", "third")
      fourth = commit_file(path, "fourth.txt", "fourth\n", "fourth")

      assert {:error, %Error{kind: :invalid_argument, message: "Only consecutive" <> _}} =
               Core.squash(repository, [second, fourth], "gap")

      assert {:error, %Error{kind: :invalid_argument}} = Core.squash(repository, [third], "one")

      assert {:error, %Error{kind: :invalid_argument}} =
               Core.squash(repository, [third, fourth], "")

      git!(path, ["checkout", "-q", "-b", "side", second])
      side = commit_file(path, "side.txt", "side\n", "side")
      git!(path, ["checkout", "-q", "main"])
      git!(path, ["merge", "--no-ff", "-m", "merge side", "side"])
      merge = git!(path, ["rev-parse", "HEAD"])

      assert {:error, %Error{message: "A merge commit" <> _}} =
               Core.squash(repository, [merge, fourth], "merge")

      # Consecutive, but on a line merged in rather than the branch's own.
      assert {:error, %Error{message: "Only commits on the checked-out branch" <> _}} =
               Core.squash(repository, [side, second], "side")

      File.write!(Path.join(path, "README.md"), "dirty\n")

      assert {:error, %Error{message: "Working tree must be clean"}} =
               Core.squash(repository, [third, fourth], "dirty")

      git!(path, ["checkout", "--", "README.md"])
      git!(path, ["checkout", "-q", "--detach", "HEAD"])

      assert {:error, %Error{kind: :unsupported}} =
               Core.squash(repository, [third, fourth], "detached")

      assert git!(path, ["rev-parse", "main~3"]) == second
      assert git!(path, ["rev-parse", "main~4"]) == initial
    end
  end

  test "stages and unstages exactly the selected files", %{path: path, repository: repository} do
    first = Path.join(path, "first.txt")
    literal = Path.join(path, "literal[1].txt")
    File.write!(first, "first\n")
    File.write!(literal, "literal\n")

    assert {:ok, %CommandResult{action: :stage}} = Core.stage(repository, [first])
    assert git!(path, ["diff", "--cached", "--name-only"]) == "first.txt"

    assert {:ok, %CommandResult{action: :stage}} =
             Core.stage(repository, ["literal[1].txt"])

    assert git!(path, ["diff", "--cached", "--name-only"]) ==
             "first.txt\nliteral[1].txt"

    assert {:ok, %CommandResult{action: :unstage}} = Core.unstage(repository, [first])
    assert git!(path, ["diff", "--cached", "--name-only"]) == "literal[1].txt"

    assert {:error, %Error{kind: :invalid_argument}} = Core.stage(repository, [])

    assert {:error, %Error{kind: :invalid_argument}} =
             Core.stage(repository, [Path.join(path, "../outside.txt")])
  end

  describe "discard/2" do
    test "returns exactly the selected files to HEAD", %{path: path, repository: repository} do
      commit_file(path, "tracked.txt", "committed\n", "add tracked")
      commit_file(path, "removed.txt", "removed\n", "add removed")
      commit_file(path, "kept.txt", "kept\n", "add kept")

      # Both sides of one file, a staged addition, a deletion, and untracked files.
      File.write!(Path.join(path, "tracked.txt"), "staged\n")
      git!(path, ["add", "tracked.txt"])
      File.write!(Path.join(path, "tracked.txt"), "staged and then edited\n")
      File.write!(Path.join(path, "added[1].txt"), "added\n")
      git!(path, ["add", "added[1].txt"])
      File.rm!(Path.join(path, "removed.txt"))
      File.write!(Path.join(path, "scratch.txt"), "scratch\n")
      File.write!(Path.join(path, "kept.txt"), "kept edit\n")
      File.write!(Path.join(path, "untouched.txt"), "untouched\n")

      selection = [
        Path.join(path, "tracked.txt"),
        "added[1].txt",
        "removed.txt",
        "scratch.txt",
        "README.md"
      ]

      assert {:ok, %CommandResult{action: :discard, output: output}} =
               Core.discard(repository, selection)

      assert output =~ "scratch.txt"
      assert File.read!(Path.join(path, "tracked.txt")) == "committed\n"
      refute File.exists?(Path.join(path, "added[1].txt"))
      assert File.read!(Path.join(path, "removed.txt")) == "removed\n"
      refute File.exists?(Path.join(path, "scratch.txt"))

      assert git!(path, ["status", "--porcelain", "--untracked-files=all"]) ==
               " M kept.txt\n?? untouched.txt"
    end

    test "restores the old path of a staged rename", %{path: path, repository: repository} do
      git!(path, ["mv", "README.md", "RENAMED.md"])

      assert {:ok, _result} = Core.discard(repository, ["RENAMED.md"])

      assert File.read!(Path.join(path, "README.md")) == "initial\n"
      refute File.exists?(Path.join(path, "RENAMED.md"))
      assert git!(path, ["status", "--porcelain", "--untracked-files=all"]) == ""
    end

    test "keeps an unselected untracked file that took a renamed path", context do
      %{path: path, repository: repository} = context
      git!(path, ["mv", "README.md", "RENAMED.md"])
      File.write!(Path.join(path, "README.md"), "someone else\n")

      assert {:ok, _result} = Core.discard(repository, ["RENAMED.md"])

      assert File.read!(Path.join(path, "README.md")) == "someone else\n"
      refute File.exists?(Path.join(path, "RENAMED.md"))
      assert git!(path, ["status", "--porcelain", "--untracked-files=all"]) == " M README.md"

      git!(path, ["mv", "README.md", "RENAMED.md"])
      File.write!(Path.join(path, "README.md"), "someone else\n")

      assert {:ok, _result} = Core.discard(repository, ["RENAMED.md", "README.md"])

      assert File.read!(Path.join(path, "README.md")) == "initial\n"
      assert git!(path, ["status", "--porcelain", "--untracked-files=all"]) == ""
    end

    test "leaves ignored and unchanged files alone", %{path: path, repository: repository} do
      commit_file(path, ".gitignore", "*.log\n", "ignore logs")
      File.write!(Path.join(path, "debug.log"), "ignored\n")

      assert {:ok, %CommandResult{output: ""}} =
               Core.discard(repository, ["debug.log", "README.md"])

      assert File.read!(Path.join(path, "debug.log")) == "ignored\n"
    end

    test "resolves a conflicted file to HEAD", %{path: path, repository: repository} do
      git!(path, ["checkout", "-b", "other"])
      commit_file(path, "README.md", "theirs\n", "theirs")
      git!(path, ["checkout", "main"])
      commit_file(path, "README.md", "ours\n", "ours")
      assert {:error, %Error{kind: :conflict}} = Core.merge(repository, "other")

      assert {:ok, _result} = Core.discard(repository, ["README.md"])

      assert File.read!(Path.join(path, "README.md")) == "ours\n"
      assert git!(path, ["diff", "--name-only", "--diff-filter=U"]) == ""
    end

    test "deletes staged files in a repository without commits", %{base: base} do
      path = Path.join(base, "unborn")
      File.mkdir_p!(path)
      git!(path, ["init", "--initial-branch=main"])
      File.write!(Path.join(path, "staged.txt"), "staged\n")
      git!(path, ["add", "staged.txt"])
      File.write!(Path.join(path, "staged.txt"), "staged and edited\n")
      File.write!(Path.join(path, "untracked.txt"), "untracked\n")
      {:ok, repository} = Core.open(path)

      assert {:ok, _result} = Core.discard(repository, ["staged.txt"])

      refute File.exists?(Path.join(path, "staged.txt"))
      assert git!(path, ["status", "--porcelain", "--untracked-files=all"]) == "?? untracked.txt"
    end

    test "validates the selection", %{path: path, repository: repository} do
      assert {:error, %Error{kind: :invalid_argument}} = Core.discard(repository, [])
      assert {:error, %Error{kind: :invalid_argument}} = Core.discard(repository, [path])

      assert {:error, %Error{kind: :invalid_argument}} =
               Core.discard(repository, [Path.join(path, "../outside.txt")])
    end
  end

  test "stashes selected tracked and untracked files and manages the stash", context do
    %{path: path, repository: repository} = context

    File.write!(Path.join(path, "README.md"), "selected tracked change\n")
    File.write!(Path.join(path, "selected.txt"), "selected untracked change\n")
    File.write!(Path.join(path, "unselected.txt"), "leave this alone\n")

    assert {:ok, %CommandResult{action: :stash}} =
             Core.stash(repository, ["README.md", "selected.txt"], message: "selected work")

    assert File.read!(Path.join(path, "README.md")) == "initial\n"
    refute File.exists?(Path.join(path, "selected.txt"))
    assert File.read!(Path.join(path, "unselected.txt")) == "leave this alone\n"

    assert {:ok, [%Stash{} = stash]} = Core.list_stashes(repository)
    assert stash.index == 0
    assert stash.reference == "stash@{0}"
    assert stash.summary =~ "selected work"
    assert %DateTime{} = stash.created_at

    assert {:ok, %CommandResult{action: :apply_stash}} =
             Core.apply_stash(repository, stash.reference)

    assert File.read!(Path.join(path, "README.md")) == "selected tracked change\n"
    assert File.read!(Path.join(path, "selected.txt")) == "selected untracked change\n"
    assert {:ok, [_stash]} = Core.list_stashes(repository)

    git!(path, ["reset", "--hard", "HEAD"])
    File.rm!(Path.join(path, "selected.txt"))

    assert {:ok, %CommandResult{action: :pop_stash}} = Core.pop_stash(repository)
    assert File.read!(Path.join(path, "README.md")) == "selected tracked change\n"
    assert File.read!(Path.join(path, "selected.txt")) == "selected untracked change\n"
    assert {:ok, []} = Core.list_stashes(repository)

    git!(path, ["reset", "--hard", "HEAD"])
    File.write!(Path.join(path, "README.md"), "another change\n")
    assert {:ok, _result} = Core.stash(repository, ["README.md"])
    assert {:ok, %CommandResult{action: :drop_stash}} = Core.drop_stash(repository)
    assert {:ok, []} = Core.list_stashes(repository)
  end

  test "reports a conflicted operation and can abort it", %{path: path, repository: repository} do
    assert {:ok, _result} = Core.create_branch(repository, "conflicting")
    File.write!(Path.join(path, "README.md"), "main version\n")
    git!(path, ["add", "README.md"])
    git!(path, ["commit", "-m", "main change"])

    assert {:ok, _result} = Core.checkout_branch(repository, "conflicting")
    File.write!(Path.join(path, "README.md"), "branch version\n")
    git!(path, ["add", "README.md"])
    git!(path, ["commit", "-m", "branch change"])
    assert {:ok, _result} = Core.checkout_branch(repository, "main")

    assert {:error, %Error{kind: :conflict, operation: operation}} =
             Core.merge(repository, "conflicting")

    assert operation.kind == :merge
    assert operation.targets != []

    assert {:ok, snapshot} = Core.snapshot(repository)
    assert snapshot.operation.kind == :merge

    assert {:ok, %CommandResult{action: :abort_operation}} = Core.abort_operation(repository)
    assert {:ok, nil} = Core.operation(repository)
    assert File.read!(Path.join(path, "README.md")) == "main version\n"
  end

  test "validates branch names and reset modes", %{repository: repository} do
    assert {:error, %Error{kind: :invalid_argument}} =
             Core.create_branch(repository, "--malicious")

    assert {:error, %Error{kind: :invalid_argument}} = Core.reset(repository, "HEAD", :mixed)
    assert {:error, %Error{kind: :invalid_argument}} = Core.cherry_pick(repository, [])
  end

  test "keeps a detached, unreferenced HEAD in the graph", %{path: path, repository: repository} do
    assert {:ok, _result} = Core.checkout_commit(repository, "HEAD")
    detached_head = commit_file(path, "detached.txt", "detached\n", "detached work")

    assert {:ok, snapshot} = Core.snapshot(repository)
    assert snapshot.detached?
    assert snapshot.current_branch == nil
    assert snapshot.head == detached_head
    assert Enum.any?(snapshot.commits, &(&1.id == detached_head))
  end

  describe "clone/3" do
    test "clones a repository into a new folder and opens it", context do
      %{base: base, path: path} = context
      destination = Path.join([base, "cloned", "target"])

      assert {:ok, %Repository{} = clone} = Core.clone(path, destination)
      assert clone.path == destination
      assert File.read!(Path.join(destination, "README.md")) == "initial\n"

      assert {:ok, snapshot} = Core.snapshot(clone)
      assert snapshot.current_branch == "main"
      assert length(snapshot.commits) == 1
    end

    test "refuses a destination that already holds something", context do
      %{base: base, path: path} = context
      destination = Path.join(base, "occupied")
      File.mkdir_p!(destination)
      File.write!(Path.join(destination, "keep.txt"), "keep\n")

      assert {:error, %Error{kind: :invalid_argument}} = Core.clone(path, destination)
      assert File.exists?(Path.join(destination, "keep.txt"))

      file = Path.join(base, "a-file")
      File.write!(file, "")
      assert {:error, %Error{kind: :invalid_argument}} = Core.clone(path, file)
    end

    test "reports what Git said when the source cannot be cloned", %{base: base} do
      assert {:error, %Error{kind: :command_failed} = error} =
               Core.clone(Path.join(base, "missing.git"), Path.join(base, "nowhere"))

      assert error.message =~ "repository"
    end

    test "validates its arguments", %{base: base, path: path} do
      assert {:error, %Error{kind: :invalid_argument}} = Core.clone("", Path.join(base, "x"))
      assert {:error, %Error{kind: :invalid_argument}} = Core.clone(path, "")

      assert {:error, %Error{kind: :invalid_argument}} =
               Core.clone(path, Path.join(base, "keys"),
                 private_key: "/nope",
                 public_key: "/nope"
               )
    end

    test "clone_name/1 derives the folder Git would create" do
      assert Core.clone_name("git@github.com:owner/mdt_client.git") == "mdt_client"
      assert Core.clone_name("https://github.com/owner/mdt-client") == "mdt-client"
      assert Core.clone_name("https://host/group/project.git/") == "project"
      assert Core.clone_name("/srv/git/local-repo") == "local-repo"
      assert Core.clone_name("") == ""
      assert Core.clone_name(nil) == ""
    end
  end

  describe "tags" do
    test "lists lightweight and annotated tags resolved to their commits", context do
      %{path: path, repository: repository, initial_commit: initial} = context
      second = commit_file(path, "second.txt", "second\n", "second commit")

      git!(path, ["tag", "plain", initial])
      git!(path, ["tag", "-a", "release", "-m", "the first release"])

      assert {:ok, tags} = Core.list_tags(repository)
      assert [%Tag{name: "plain"}, %Tag{name: "release"}] = Enum.sort_by(tags, & &1.name)

      plain = Enum.find(tags, &(&1.name == "plain"))
      assert plain.full_name == "refs/tags/plain"
      assert plain.target == initial
      assert plain.object == initial
      refute plain.annotated?

      release = Enum.find(tags, &(&1.name == "release"))
      assert release.target == second
      assert release.object != second
      assert release.annotated?
    end

    test "a snapshot carries tags and labels the commits they point at", context do
      %{path: path, repository: repository, initial_commit: initial} = context
      commit_file(path, "second.txt", "second\n", "second commit")
      git!(path, ["tag", "v1", initial])

      assert {:ok, snapshot} = Core.snapshot(repository)
      assert [%Tag{name: "v1"}] = snapshot.tags

      tagged = Enum.find(snapshot.commits, &(&1.id == initial))
      assert Enum.any?(tagged.labels, &match?(%Tag{name: "v1"}, &1))

      # Branch labels are untouched by the addition.
      head = List.first(snapshot.commits)
      assert Enum.any?(head.labels, &match?(%{name: "main"}, &1))
    end

    test "get_commit labels a commit with its tags", context do
      %{path: path, repository: repository, initial_commit: initial} = context
      git!(path, ["tag", "-a", "annotated", "-m", "note", initial])

      assert {:ok, commit} = Core.get_commit(repository, initial)
      assert Enum.any?(commit.labels, &match?(%Tag{name: "annotated", annotated?: true}, &1))
    end

    test "a repository with no tags reports none", %{repository: repository} do
      assert {:ok, []} = Core.list_tags(repository)
      assert {:ok, %{tags: []}} = Core.snapshot(repository)
    end
  end
end
