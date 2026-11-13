defmodule MDTClient.Sandbox.PullRequestsTest do
  @moduledoc """
  Pull requests through the sandbox of an unlocked identity, as the agent
  channel and the page use them. A folder of this machine stands in for the
  VM: the agent's repository is a clone of yours in it, as when it was
  cloned from a shared folder. `vm_live_test.exs` has the real VM.
  """
  # The stand-in is application config, so these tests take turns.
  use ExUnit.Case, async: false

  alias MDTClient.Sandbox
  alias MDTClient.Sandbox.{Channel, Guest, Landing, PullRequest, PullRequests, PullTarget, Share}

  doctest MDTClient.Sandbox.PullTarget

  @me [
    {"GIT_AUTHOR_NAME", "Someone"},
    {"GIT_AUTHOR_EMAIL", "someone@example.test"},
    {"GIT_COMMITTER_NAME", "Someone"},
    {"GIT_COMMITTER_EMAIL", "someone@example.test"}
  ]

  defp git(dir, args) do
    case System.cmd("git", ["-C", dir | args],
           env: @me ++ Guest.git_env(),
           stderr_to_stdout: true
         ) do
      {output, 0} -> output
      {output, status} -> flunk("git #{Enum.join(args, " ")} exited #{status}: #{output}")
    end
  end

  defp commit(dir, files, message) do
    Enum.each(files, fn {name, text} -> File.write!(Path.join(dir, name), text) end)
    git(dir, ["add", "--all"])
    git(dir, ["commit", "-q", "-m", message])
  end

  setup do
    %{username: username} = MDTClient.VaultHelpers.unlocked_identity("pulls")
    base = Path.join(System.tmp_dir!(), "pulls-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(base) end)

    repo = Path.join(base, "host/app")
    File.mkdir_p!(repo)
    git(repo, ["init", "-q", "-b", "master"])
    commit(repo, [{"a.txt", "one\ntwo\nthree\n"}], "first")

    vm = Path.join(base, "vm")
    File.mkdir_p!(vm)
    Application.put_env(:mdt_client, PullRequests, guest: Guest.local(vm))
    on_exit(fn -> Application.delete_env(:mdt_client, PullRequests) end)

    # The agent's clone, on a branch of its own.
    clone = Path.join(vm, "app")
    {_, 0} = System.cmd("git", ["clone", "-q", repo, clone], env: Guest.git_env())
    git(clone, ["checkout", "-q", "-b", "fix"])

    %{username: username, repo: repo, clone: clone, base: base}
  end

  defp ask(clone, extra \\ %{}),
    do:
      Map.merge(
        %{"cwd" => clone, "title" => "The fix", "body" => "Done.", "agent" => "claude"},
        extra
      )

  defp pulls(username), do: Sandbox.snapshot(username).pulls

  defp choice(how, where), do: %{how: how, where: where}

  test "an agent opens one from its clone; your repository is untouched until you bring it in", %{
    username: username,
    repo: repo,
    clone: clone
  } do
    commit(clone, [{"a.txt", "one\ntwo\nthree\nfour\n"}, {"b.txt", "new\n"}], "the fix")
    refs = git(repo, ["for-each-ref"])
    objects = git(repo, ["count-objects", "-v"])

    assert {0, said} = Channel.answer("pr", ask(clone), username)
    assert said =~ "Opened pull request #1: fix into the user's master"

    assert [
             %PullRequest{
               id: 1,
               repo: ^repo,
               base: "master",
               status: :open,
               revision: 1,
               agent: "claude",
               stats: %{commits: 1, files: 2, conflicts: 0}
             }
           ] = pulls(username)

    assert git(repo, ["for-each-ref"]) == refs
    assert git(repo, ["count-objects", "-v"]) == objects

    assert {:ok, facts} = PullRequests.facts(username, 1)
    assert Enum.map(facts.files, & &1.path) == ["a.txt", "b.txt"]
    assert [%{subject: "the fix"}] = facts.commits
    assert facts.conflicts == [] and facts.behind == 0

    assert {:ok, %{files: [a, b], cut?: false}} =
             PullRequests.diff(username, 1, facts.merge_base)

    assert a.path == "a.txt" and b.path == "b.txt"
    assert [%{lines: lines}] = a.hunks
    assert Enum.any?(lines, &(&1.kind == :added and &1.text == "four"))

    # More commits on the branch update it: same number, a new revision.
    commit(clone, [{"c.txt", "more\n"}], "more")
    assert {0, updated} = Channel.answer("pr", %{"cwd" => clone}, username)
    assert updated =~ "Updated pull request #1 (revision 2)"

    assert [%PullRequest{id: 1, revision: 2, title: "The fix", stats: %{commits: 2}}] =
             pulls(username)

    assert git(repo, ["for-each-ref"]) == refs

    assert {0, listed} = Channel.answer("prs", %{"cwd" => clone}, username)
    assert listed =~ "#1  open, waiting for the user" and listed =~ "merges cleanly"
  end

  test "what isn't a finished branch is refused, with words for the agent", %{
    username: username,
    clone: clone,
    base: base
  } do
    assert {1, untitled} = Channel.answer("pr", %{"cwd" => clone}, username)
    assert untitled =~ "Give it a title"

    File.write!(Path.join(clone, "a.txt"), "changed\n")
    assert {1, dirty} = Channel.answer("pr", ask(clone), username)
    assert dirty =~ "Commit or discard these first" and dirty =~ "a.txt"
    git(clone, ["checkout", "-q", "--", "a.txt"])

    git(clone, ["checkout", "-q", "--detach"])
    assert {1, detached} = Channel.answer("pr", ask(clone), username)
    assert detached =~ "on no branch"

    assert {1, nowhere} = Channel.answer("pr", ask(base), username)
    assert nowhere =~ "isn't in a git repository"

    # A repository with no history in common with yours.
    other = Path.join(base, "vm/other")
    File.mkdir_p!(other)
    git(other, ["init", "-q", "-b", "work"])
    git(other, ["remote", "add", "origin", Path.join(base, "host/app")])
    commit(other, [{"x.txt", "x\n"}], "unrelated")
    assert {1, unrelated} = Channel.answer("pr", ask(other), username)
    assert unrelated =~ "shares no history"
    assert pulls(username) == []

    Application.delete_env(:mdt_client, PullRequests)
    assert {1, "The VM isn't running."} = Channel.answer("pr", ask(clone), username)
  end

  describe "which repository it is for" do
    test "comes from a remote that is a path here, a path the agent names, or a remote you know",
         %{repo: repo, base: base} do
      assert PullTarget.resolve(nil, %{top: "/work/app", remotes: [repo]}, []) == {:ok, repo}

      sub = Path.join(repo, "lib")
      File.mkdir_p!(sub)
      assert PullTarget.resolve(sub, %{top: "/work/app", remotes: []}, []) == {:ok, repo}

      git(repo, ["remote", "add", "origin", "https://github.com/me/app.git"])
      vm = %{top: "/work/app", remotes: ["git@github.com:me/app.git"]}
      assert PullTarget.resolve(nil, vm, [repo]) == {:ok, repo}
      assert PullTarget.resolve(nil, vm, []) == {:error, :no_target}

      assert PullTarget.resolve(nil, %{vm | remotes: ["git@github.com:me/other.git"]}, [repo]) ==
               {:error, :no_target}

      assert {:error, {:not_a_repository, _}} =
               PullTarget.resolve(base, %{top: "/work", remotes: []}, [])

      assert {:error, {:not_a_repository, _}} =
               PullTarget.resolve("relative/path", %{top: "/work", remotes: []}, [])
    end

    test "is never one the VM can write, or one holding what it must not reach", %{
      repo: repo,
      base: base
    } do
      shares = [%Share{path: Path.join(base, "host"), mode: :rw}]

      assert PullTarget.check(repo, shares: shares) ==
               {:error, {:writable, Path.join(base, "host")}}

      assert PullTarget.check(repo, shares: [%{hd(shares) | mode: :ro}]) == {:ok, repo}

      assert {:error, {:refused, _, "MDT's own data"}} =
               PullTarget.check(repo, data_dir: Path.join(base, "host"))

      assert {:error, :no_target} =
               PullTarget.resolve(nil, %{top: "/x", remotes: [repo]}, [], shares: shares)
    end
  end

  describe "bringing it in" do
    setup %{username: username, clone: clone} do
      commit(clone, [{"a.txt", "one\ntwo\nthree\nfour\n"}, {"b.txt", "new\n"}], "the fix")
      {0, _} = Channel.answer("pr", ask(clone), username)
      :ok
    end

    test "only the changes, uncommitted, merged with your own edits; undo puts them back", %{
      username: username,
      repo: repo
    } do
      File.write!(Path.join(repo, "mine.txt"), "staged\n")
      git(repo, ["add", "mine.txt"])
      File.write!(Path.join(repo, "a.txt"), "ONE\ntwo\nthree\n")
      head = git(repo, ["rev-parse", "HEAD"])
      status = git(repo, ["status", "--porcelain"])

      assert {:ok, %{worktrees: [%{path: ^repo, branch: "master", changes: 2, main?: true}]}} =
               PullRequests.destinations(username, 1)

      where = {:worktree, repo}
      assert {:ok, %{conflicts: []}} = PullRequests.preview(username, 1, choice(:changes, where))

      assert {:ok, %PullRequest{status: :merged, landed: %{how: :changes, branch: "master"}}} =
               PullRequests.land(username, 1, choice(:changes, where))

      assert File.read!(Path.join(repo, "a.txt")) == "ONE\ntwo\nthree\nfour\n"
      assert File.read!(Path.join(repo, "b.txt")) == "new\n"
      assert git(repo, ["rev-parse", "HEAD"]) == head
      assert git(repo, ["diff", "--cached", "--name-only"]) == "mine.txt\n"
      refute git(repo, ["for-each-ref"]) =~ "refs/mdt/pulls/"

      assert {:ok, %PullRequest{status: :open, landed: nil}} = PullRequests.undo(username, 1)
      assert git(repo, ["status", "--porcelain"]) == status
      assert File.read!(Path.join(repo, "a.txt")) == "ONE\ntwo\nthree\n"
    end

    test "the agent's commits: a fast-forward of your branch, undone while it stays there", %{
      username: username,
      repo: repo,
      clone: clone
    } do
      before = git(repo, ["rev-parse", "HEAD"])
      where = {:worktree, repo}

      assert {:ok, %{conflicts: [], fast_forward?: true}} =
               PullRequests.preview(username, 1, choice(:commits, where))

      assert {:ok, %PullRequest{landed: %{how: :commits}}} =
               PullRequests.land(username, 1, choice(:commits, where))

      assert git(repo, ["rev-parse", "HEAD"]) == git(clone, ["rev-parse", "HEAD"])
      assert git(repo, ["log", "-1", "--format=%s %an"]) == "the fix Someone\n"
      assert git(repo, ["status", "--porcelain"]) == ""

      assert {:ok, _} = PullRequests.undo(username, 1)
      assert git(repo, ["rev-parse", "HEAD"]) == before
    end

    test "a new branch, or a new worktree on a new branch", %{
      username: username,
      repo: repo,
      base: base
    } do
      head = git(repo, ["rev-parse", "HEAD"])

      assert {:error, {:branch_taken, "master"}} =
               PullRequests.preview(username, 1, choice(:commits, {:new_branch, "master"}))

      assert {:error, :needs_a_worktree} =
               PullRequests.preview(username, 1, choice(:changes, {:new_branch, "x"}))

      assert {:ok, %PullRequest{landed: %{branch: "agent-fix", worktree: nil}}} =
               PullRequests.land(username, 1, choice(:commits, {:new_branch, "agent-fix"}))

      assert git(repo, ["log", "-1", "--format=%s", "agent-fix"]) == "the fix\n"
      assert git(repo, ["rev-parse", "HEAD"]) == head
      assert {:ok, _} = PullRequests.undo(username, 1)
      assert git(repo, ["branch", "--list", "agent-fix"]) == ""

      tree = Path.join(base, "host/app-fix")

      assert {:error, {:path_taken, _}} =
               PullRequests.preview(username, 1, choice(:changes, {:new_worktree, repo, "x"}))

      assert {:ok, %PullRequest{landed: %{worktree: ^tree, branch: "fix-here"}}} =
               PullRequests.land(username, 1, choice(:changes, {:new_worktree, tree, "fix-here"}))

      assert File.read!(Path.join(tree, "b.txt")) == "new\n"
      assert git(tree, ["status", "--porcelain"]) == " M a.txt\n?? b.txt\n"
      assert git(tree, ["rev-parse", "HEAD"]) == head
      assert [_, %{path: ^tree, branch: "fix-here"}] = Landing.worktrees(repo)

      assert {:ok, _} = PullRequests.undo(username, 1)
      refute File.exists?(tree)
      assert git(repo, ["branch", "--list", "fix-here"]) == ""
    end
  end

  test "conflicts show; sent back with your branch, the agent merges it and updates the pull request",
       %{username: username, repo: repo, clone: clone} do
    commit(clone, [{"a.txt", "one\nTWO from the vm\nthree\n"}], "the fix")
    {0, _} = Channel.answer("pr", ask(clone), username)
    commit(repo, [{"a.txt", "one\ntwo, yours\nthree\n"}], "yours")

    assert {:ok, %{conflicts: ["a.txt"], behind: 1}} = PullRequests.facts(username, 1)
    where = {:worktree, repo}

    assert {:ok, %{conflicts: ["a.txt"]}} =
             PullRequests.preview(username, 1, choice(:changes, where))

    assert {:error, {:conflicts, ["a.txt"]}} =
             PullRequests.land(username, 1, choice(:commits, where))

    assert {:error, {:conflicts, ["a.txt"]}} =
             PullRequests.land(username, 1, choice(:changes, where))

    assert git(repo, ["status", "--porcelain"]) == ""

    assert {:ok, %PullRequest{status: :changes_requested}} =
             PullRequests.send_back(username, 1, "Keep my wording.", true)

    assert git(clone, ["rev-parse", "refs/remotes/host/master"]) ==
             git(repo, ["rev-parse", "master"])

    assert {0, listed} = Channel.answer("prs", %{"cwd" => clone}, username)
    assert listed =~ "sent back to you" and listed =~ "Keep my wording."
    assert listed =~ "git merge host/master" and listed =~ "conflicts with their master in: a.txt"

    # The agent merges your branch, resolves, and updates it.
    System.cmd("git", ["-C", clone, "merge", "-q", "host/master"], env: @me ++ Guest.git_env())
    File.write!(Path.join(clone, "a.txt"), "one\ntwo, yours\nthree\n")
    commit(clone, [{"b.txt", "and more\n"}], "merge yours")

    assert {0, said} = Channel.answer("pr", %{"cwd" => clone}, username)
    assert said =~ "revision 2"
    assert [%PullRequest{status: :open, stats: %{conflicts: 0}}] = pulls(username)

    assert {:ok, _} = PullRequests.land(username, 1, choice(:commits, where))
    assert File.read!(Path.join(repo, "b.txt")) == "and more\n"
  end

  test "closed and reopened; bringing in what isn't open is refused", %{
    username: username,
    clone: clone,
    repo: repo
  } do
    commit(clone, [{"b.txt", "new\n"}], "the fix")
    {0, _} = Channel.answer("pr", ask(clone), username)

    assert {:ok, %PullRequest{status: :closed}} = PullRequests.close(username, 1)

    assert PullRequests.land(username, 1, choice(:changes, {:worktree, repo})) ==
             {:error, :not_open}

    assert {:ok, %PullRequest{status: :open}} = PullRequests.reopen(username, 1)
    assert {:error, :not_closed} = PullRequests.reopen(username, 1)

    # Closed, the branch opens a new one next time.
    {:ok, _} = PullRequests.close(username, 1)
    assert {0, said} = Channel.answer("pr", ask(clone), username)
    assert said =~ "Opened pull request #2"

    assert [:pull | _] =
             username |> Sandbox.events() |> Enum.map(& &1.outcome) |> Enum.uniq()
  end
end
