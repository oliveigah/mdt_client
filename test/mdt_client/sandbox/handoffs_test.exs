defmodule MDTClient.Sandbox.HandoffsTest do
  @moduledoc """
  Projects, their mirrors, agent worktrees and handoffs, through the
  sandbox of an unlocked identity, as the agent channel and the pages use
  them. A folder of this machine stands in for the VM's Work disk;
  `vm_live_test.exs` has the real VM.
  """
  # The stand-in is application config, so these tests take turns.
  use ExUnit.Case, async: false

  alias MDTClient.Sandbox
  alias MDTClient.Sandbox.{Channel, Guest, Handoff, Handoffs, Mirror, Project, Projects, Share}

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

  defp sha(dir, rev), do: dir |> git(["rev-parse", rev]) |> String.trim()

  setup do
    %{username: username} = MDTClient.VaultHelpers.unlocked_identity("handoffs")
    base = Path.join(System.tmp_dir!(), "handoffs-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(base) end)

    repo = Path.join(base, "host/app")
    File.mkdir_p!(repo)
    git(repo, ["init", "-q", "-b", "master"])
    commit(repo, [{"a.txt", "one\ntwo\nthree\n"}], "first")

    vm = Path.join(base, "vm")
    File.mkdir_p!(vm)
    Application.put_env(:mdt_client, Projects, guest: Guest.local(vm))
    on_exit(fn -> Application.delete_env(:mdt_client, Projects) end)

    %{username: username, repo: repo, vm: vm, base: base, mirror: Path.join(vm, "app")}
  end

  # A project, and an agent worktree of it made the way an agent makes one.
  defp project_with_worktree(%{username: username, repo: repo, mirror: mirror}, task \\ "fix") do
    {:ok, project} = Projects.add(username, repo)
    {0, _} = Channel.answer("worktree", %{"cwd" => mirror, "name" => task}, username)
    {project, Path.join(mirror <> ".wt", task)}
  end

  defp ask(cwd, extra \\ %{}),
    do:
      Map.merge(
        %{
          "cwd" => cwd,
          "title" => "The fix",
          "body" => "Done.",
          "agent" => "claude",
          "thread" => "Fix the login"
        },
        extra
      )

  defp handoffs(username), do: Sandbox.snapshot(username).handoffs

  describe "a project" do
    test "opening a repository makes it one, with a mirror of its branch", %{
      username: username,
      repo: repo,
      mirror: mirror,
      base: base
    } do
      assert {:ok,
              %Project{name: "app", path: ^repo, default_target: "master", targets: ["master"]}} =
               Projects.add(username, Path.join(repo, "."))

      # Opening it again is the same project.
      assert {:ok, %Project{name: "app"}} = Projects.add(username, repo)
      assert [%Project{}] = Projects.list(username)

      assert File.read!(Path.join(mirror, "a.txt")) == "one\ntwo\nthree\n"
      assert sha(mirror, "HEAD") == sha(repo, "master")
      assert git(mirror, ["branch", "--show-current"]) == "master\n"
      assert sha(mirror, "host") == sha(repo, "master")

      assert %{"app" => %{error: nil, default: "master", rescued: nil}} =
               Sandbox.snapshot(username).mirror

      assert {:error, {:not_a_repository, _}} = Projects.add(username, base)
      shares = [%Share{path: Path.join(base, "host"), mode: :rw}]
      assert Project.check(repo, shares: shares) == {:error, {:writable, Path.join(base, "host")}}

      assert {:error, {:refused, _, "MDT's own data"}} =
               Project.check(repo, data_dir: Path.join(base, "host"))
    end

    test "its mirror follows your branch, and keeps what was done in it on a branch", %{
      username: username,
      repo: repo,
      mirror: mirror
    } do
      {:ok, _} = Projects.add(username, repo)
      commit(repo, [{"b.txt", "yours\n"}], "second")
      File.write!(Path.join(repo, "uncommitted.txt"), "never travels\n")

      assert {:ok, %{rescued: nil}} = Projects.mirror(username, "app")
      assert File.read!(Path.join(mirror, "b.txt")) == "yours\n"
      refute File.exists?(Path.join(mirror, "uncommitted.txt"))

      # Someone edits and commits in the mirror.
      File.write!(Path.join(mirror, "a.txt"), "changed in the mirror\n")
      File.write!(Path.join(mirror, "new.txt"), "new in the mirror\n")
      commit(repo, [{"c.txt", "more\n"}], "third")

      assert {:ok, %{rescued: "rescued/" <> _ = kept}} = Projects.mirror(username, "app")
      assert git(mirror, ["status", "--porcelain"]) == ""
      assert sha(mirror, "HEAD") == sha(repo, "master")
      assert git(mirror, ["show", "#{kept}:new.txt"]) == "new in the mirror\n"

      assert [%{summary: "Edits found in the mirror of app, kept in the VM as " <> _} | _] =
               for(%{outcome: :project} = e <- Sandbox.events(username), do: e)
    end

    test "the server's look updates a mirror only when something moved", %{
      username: username,
      repo: repo,
      mirror: mirror
    } do
      {:ok, _} = Projects.add(username, repo)
      vm = %{name: "vm", status: :running, started_at: nil}
      %{projects: projects, mirror: entries} = Sandbox.snapshot(username)
      entries = Map.new(entries, fn {name, entry} -> {name, %{entry | vm_started_at: nil}} end)

      # Nothing moved: a stray file stays where it is.
      File.write!(Path.join(mirror, "stray.txt"), "x\n")
      :ok = Projects.follow(username, projects, entries, vm, 60)
      assert File.exists?(Path.join(mirror, "stray.txt"))

      commit(repo, [{"b.txt", "yours\n"}], "second")
      :ok = Projects.follow(username, projects, entries, vm, 60)
      refute File.exists?(Path.join(mirror, "stray.txt"))
      assert sha(mirror, "HEAD") == sha(repo, "master")
      assert Mirror.tips(hd(projects)) == %{"master" => sha(repo, "master")}
    end

    test "its settings choose the target branches, and the mirror has each", %{
      username: username,
      repo: repo,
      mirror: mirror
    } do
      {:ok, _} = Projects.add(username, repo)
      git(repo, ["branch", "develop"])

      assert {:error, :no_targets} = Projects.update(username, "app", %{"targets" => []})

      assert {:error, {:not_a_branch, "nope"}} =
               Projects.update(username, "app", %{"targets" => ["nope"]})

      assert {:error, :default_not_a_target} =
               Projects.update(username, "app", %{
                 "targets" => ["master"],
                 "default_target" => "develop"
               })

      assert {:ok, %Project{targets: ["master", "develop"], accept: :changes}} =
               Projects.update(username, "app", %{
                 "targets" => ["master", "develop"],
                 "accept" => "changes"
               })

      assert sha(mirror, "host/develop") == sha(repo, "develop")

      {:ok, _} = Projects.update(username, "app", %{"targets" => ["master"]})
      refute git(mirror, ["for-each-ref", "refs/remotes/host/"]) =~ "develop"

      assert :ok = Projects.remove(username, "app")
      assert Projects.list(username) == []
    end
  end

  describe "an agent" do
    test "makes a worktree of its own, and is told where it is", %{
      username: username,
      repo: repo,
      mirror: mirror
    } do
      {:ok, _} = Projects.add(username, repo)

      assert {0, made} = Channel.answer("worktree", %{"cwd" => mirror, "name" => "fix"}, username)
      tree = Path.join(mirror <> ".wt", "fix")
      assert made =~ "Made the worktree #{tree}, on the new branch fix, from the user's master."
      assert made =~ "zed ssh://mdt-sandbox#{tree}"
      assert git(tree, ["branch", "--show-current"]) == "fix\n"

      assert {1, taken} = Channel.answer("worktree", %{"cwd" => tree, "name" => "fix"}, username)
      assert taken =~ "called fix already"

      assert {1, bad} =
               Channel.answer(
                 "worktree",
                 %{"cwd" => mirror, "name" => "-x", "onto" => "x"},
                 username
               )

      assert bad =~ "isn't a target branch"

      assert {0, here} = Channel.answer("project", %{"cwd" => mirror}, username)
      assert here =~ "You are in the mirror" and here =~ "view only"
      assert {0, there} = Channel.answer("project", %{"cwd" => tree}, username)
      assert there =~ "You are in the worktree #{tree}"
      assert {:ok, [%{path: ^tree, branch: "fix"}]} = Projects.worktrees(username, "app")

      assert {1, nowhere} = Channel.answer("project", %{"cwd" => "/"}, username)
      assert nowhere =~ "isn't in a project"
    end

    test "hands off from its worktree; your repository is untouched until you accept", context do
      %{username: username, repo: repo, mirror: mirror} = context
      {_project, tree} = project_with_worktree(context)

      assert {1, mirrored} = Channel.answer("handoff", ask(mirror), username)
      assert mirrored =~ "This is the project's mirror"

      File.write!(Path.join(tree, "a.txt"), "changed\n")
      assert {1, dirty} = Channel.answer("handoff", ask(tree), username)
      assert dirty =~ "Commit or discard these first"
      git(tree, ["checkout", "-q", "--", "a.txt"])

      commit(tree, [{"a.txt", "one\ntwo\nthree\nfour\n"}, {"b.txt", "new\n"}], "the fix")
      refs = git(repo, ["for-each-ref"])
      objects = git(repo, ["count-objects", "-v"])

      assert {1, untitled} = Channel.answer("handoff", %{"cwd" => tree}, username)
      assert untitled =~ "Give it a title"

      assert {1, elsewhere} =
               Channel.answer("handoff", ask(tree, %{"onto" => "develop"}), username)

      assert elsewhere =~ "develop isn't a target branch" and elsewhere =~ "master"

      assert {0, said} = Channel.answer("handoff", ask(tree), username)
      assert said =~ "Handed off as #1: fix onto the user's master."

      assert [
               %Handoff{
                 id: 1,
                 project: "app",
                 onto: "master",
                 thread: "Fix the login",
                 agent: "claude",
                 status: :open,
                 stats: %{commits: 1, files: 2, conflicts: 0}
               }
             ] = handoffs(username)

      assert git(repo, ["for-each-ref"]) == refs
      assert git(repo, ["count-objects", "-v"]) == objects

      commit(tree, [{"c.txt", "more\n"}], "more")
      assert {0, updated} = Channel.answer("handoff", %{"cwd" => tree}, username)
      assert updated =~ "Updated handoff #1 (revision 2)"
      assert [%Handoff{revision: 2, title: "The fix"}] = handoffs(username)

      assert {0, listed} = Channel.answer("handoffs", %{"cwd" => tree}, username)
      assert listed =~ "#1  open, waiting for the user (this worktree)"
      assert listed =~ "merges cleanly"
    end

    test "is refused a handoff that doesn't catch up with your branch, until it merges it",
         context do
      %{username: username, repo: repo} = context
      {_project, tree} = project_with_worktree(context)
      commit(tree, [{"a.txt", "one\nTWO from the vm\nthree\n"}], "the fix")
      {0, _} = Channel.answer("handoff", ask(tree), username)
      first = hd(handoffs(username)).head

      commit(repo, [{"a.txt", "one\ntwo, yours\nthree\n"}], "yours")
      {:ok, _} = Projects.mirror(username, "app")
      assert {:ok, %{conflicts: ["a.txt"]}} = Handoffs.facts(username, 1)

      commit(tree, [{"b.txt", "more\n"}], "more")
      assert {1, refused} = Channel.answer("handoff", %{"cwd" => tree}, username)

      assert refused =~ "doesn't merge with the user's master" and
               refused =~ "git merge host/master"

      assert [%Handoff{head: ^first, revision: 1}] = handoffs(username)

      # Catching up: the mirror's branch is right there.
      System.cmd("git", ["-C", tree, "merge", "-q", "host"], env: @me ++ Guest.git_env())
      commit(tree, [{"a.txt", "one\ntwo, yours\nthree\n"}], "merge yours")
      assert {0, said} = Channel.answer("handoff", %{"cwd" => tree}, username)
      assert said =~ "revision 2"
      assert [%Handoff{stats: %{conflicts: 0}}] = handoffs(username)
    end

    test "can only hand off from a project", %{username: username, vm: vm, repo: repo} do
      other = Path.join(vm, "other")
      {_, 0} = System.cmd("git", ["clone", "-q", repo, other], env: Guest.git_env())
      git(other, ["checkout", "-q", "-b", "work"])
      commit(other, [{"x.txt", "x\n"}], "work")
      assert {1, said} = Channel.answer("handoff", ask(other), username)
      assert said =~ "isn't a project MDT mirrors"

      Application.delete_env(:mdt_client, Projects)
      assert {1, "The VM isn't running."} = Channel.answer("handoff", ask(other), username)
    end
  end

  describe "accepting" do
    setup context do
      {_project, tree} = project_with_worktree(context)
      commit(tree, [{"a.txt", "one\ntwo\nthree\nfour\n"}, {"b.txt", "new\n"}], "the fix")
      {0, _} = Channel.answer("handoff", ask(tree), context.username)
      %{tree: tree}
    end

    test "waits for a target branch with no pending work", %{username: username, repo: repo} do
      File.write!(Path.join(repo, "a.txt"), "pending\n")

      assert {:error, {:pending, "master", ^repo, ["a.txt"]}} =
               Handoffs.preview(username, 1, :commits)

      assert {:error, {:pending, _, _, _} = pending} = Handoffs.accept(username, 1, :changes)
      assert Handoffs.explain(pending) =~ "work you haven't committed: a.txt"
      git(repo, ["checkout", "-q", "--", "a.txt"])

      # Files git doesn't track don't count.
      File.write!(Path.join(repo, "notes.txt"), "mine\n")

      assert {:ok, %{conflicts: [], fast_forward?: true}} =
               Handoffs.preview(username, 1, :commits)

      git(repo, ["checkout", "-q", "-b", "elsewhere"])
      assert {:error, {:not_checked_out, "master"}} = Handoffs.preview(username, 1, :commits)
    end

    test "as the agent's commits: a fast-forward, undone while it stays there", %{
      username: username,
      repo: repo,
      tree: tree
    } do
      before = sha(repo, "HEAD")

      assert {:ok, %Handoff{status: :accepted, accepted: %{how: :commits, branch: "master"}}} =
               Handoffs.accept(username, 1, :commits)

      assert sha(repo, "HEAD") == sha(tree, "HEAD")
      assert git(repo, ["log", "-1", "--format=%s %an"]) == "the fix Someone\n"
      refute git(repo, ["for-each-ref"]) =~ "refs/mdt/handoffs/"

      assert {:ok, %Handoff{status: :open}} = Handoffs.undo(username, 1)
      assert sha(repo, "HEAD") == before
    end

    test "as the changes only, uncommitted, undone back to clean", %{
      username: username,
      repo: repo
    } do
      head = sha(repo, "HEAD")
      assert {:ok, %Handoff{accepted: %{how: :changes}}} = Handoffs.accept(username, 1, :changes)
      assert git(repo, ["status", "--porcelain"]) == " M a.txt\n?? b.txt\n"
      assert sha(repo, "HEAD") == head

      assert {:ok, _} = Handoffs.undo(username, 1)
      assert git(repo, ["status", "--porcelain"]) == ""
    end

    test "or saved as a branch to look at, and it stays open", %{username: username, repo: repo} do
      assert Handoffs.default_branch(username, 1) == "handoff-1-fix"
      assert {:ok, "handoff-1-fix"} = Handoffs.save_branch(username, 1, "handoff-1-fix")
      assert git(repo, ["log", "-1", "--format=%s", "handoff-1-fix"]) == "the fix\n"
      assert {:error, {:branch_taken, _}} = Handoffs.save_branch(username, 1, "master")
      assert [%Handoff{status: :open}] = handoffs(username)
    end

    test "conflicts once your branch moved: sent back to its thread with a note", %{
      username: username,
      repo: repo,
      tree: tree
    } do
      commit(repo, [{"a.txt", "one\ntwo\nthree\nyours\n"}], "yours")

      assert {:error, {:conflicts, ["a.txt"]}} = Handoffs.accept(username, 1, :commits)
      assert {:error, {:conflicts, ["a.txt"]}} = Handoffs.accept(username, 1, :changes)
      assert git(repo, ["status", "--porcelain"]) == ""

      assert {:ok, %Handoff{status: :sent_back}} =
               Handoffs.send_back(username, 1, "Catch up with mine.")

      {:ok, _} = Projects.mirror(username, "app")
      assert {0, listed} = Channel.answer("handoffs", %{"cwd" => tree}, username)
      assert listed =~ "sent back to you" and listed =~ "Catch up with mine."
      assert listed =~ "conflicts with their master in: a.txt"

      assert {:ok, %Handoff{status: :closed}} = Handoffs.close(username, 1)
      assert Handoffs.accept(username, 1, :commits) == {:error, :not_open}
      assert {:ok, %Handoff{status: :open}} = Handoffs.reopen(username, 1)
    end
  end
end
