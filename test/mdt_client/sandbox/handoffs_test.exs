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
    Application.put_env(:mdt_client, MDTClient.Sandbox.Zed, open: fn _address -> :ok end)

    on_exit(fn ->
      Application.delete_env(:mdt_client, Projects)
      Application.delete_env(:mdt_client, MDTClient.Sandbox.Zed)
    end)

    # Your projects folder, shared read-only: every repository in it is a project.
    {:ok, _} = Sandbox.add_share(username, Path.join(base, "host"), :ro)

    %{username: username, repo: repo, vm: vm, base: base, mirror: Path.join(vm, "app")}
  end

  # A project, and a task started in its first worktree slot the way an
  # agent starts one.
  defp project_with_worktree(%{username: username, repo: repo, mirror: mirror}, task \\ "fix") do
    {:ok, project} = Projects.open(username, repo)
    {0, _} = Channel.answer("worktree", %{"cwd" => mirror, "name" => task}, username)
    {project, Path.join(mirror <> ".wt", "slot-1")}
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
    test "is every repository in a shared folder, and only those", %{
      username: username,
      repo: repo,
      base: base
    } do
      # Another repository beside it, deeper down; a linked worktree, a
      # dependency folder and a hidden one, which are not projects.
      other = Path.join(base, "host/group/lib")
      File.mkdir_p!(other)
      git(other, ["init", "-q", "-b", "main"])
      commit(other, [{"x.txt", "x\n"}], "x")
      git(repo, ["worktree", "add", "-q", Path.join(base, "host/app-wt"), "-b", "side"])
      File.mkdir_p!(Path.join(base, "host/node_modules/dep/.git"))
      File.mkdir_p!(Path.join(base, "host/.cache/thing/.git"))

      outside = Path.join(base, "elsewhere")
      File.mkdir_p!(outside)
      git(outside, ["init", "-q", "-b", "main"])
      commit(outside, [{"y.txt", "y\n"}], "y")

      assert %{shared: [%{share: %Share{mode: :ro}, repos: repos}], unshared: []} =
               Projects.overview(username)

      assert [
               %{path: ^repo, name: "app", branch: "master", project: nil},
               %{path: ^other, name: "lib", branch: "main", project: nil}
             ] = repos

      assert Projects.open(username, outside) == {:error, :not_shared}

      # Opened, it has its record; once its folder isn't shared, it is listed apart.
      {:ok, _} = Projects.open(username, repo)

      assert %{shared: [%{repos: [%{project: %Project{name: "app"}} | _]}]} =
               Projects.overview(username)

      :ok = Sandbox.remove_share(username, Path.join(base, "host"))
      assert %{shared: [], unshared: [%Project{name: "app"}]} = Projects.overview(username)
      assert Projects.mirror(username, "app") == {:error, :not_shared}
    end

    test "is never opened from a read-write shared folder", %{
      username: username,
      repo: repo,
      base: base
    } do
      host = Path.join(base, "host")
      :ok = Sandbox.set_share_mode(username, host, :rw)
      assert %{shared: [%{share: %Share{mode: :rw}, repos: [_]}]} = Projects.overview(username)
      assert Projects.open(username, repo) == {:error, {:writable, host}}
      assert Projects.explain({:writable, host}) =~ "which the VM can write"
    end

    test "opening a repository makes it one, with a mirror of its branch", %{
      username: username,
      repo: repo,
      mirror: mirror,
      base: base
    } do
      assert {:ok,
              %Project{name: "app", path: ^repo, default_target: "master", targets: ["master"]}} =
               Projects.open(username, Path.join(repo, "."))

      # Opening it again is the same project.
      assert {:ok, %Project{name: "app"}} = Projects.open(username, repo)
      assert [%Project{}] = Projects.list(username)

      assert File.read!(Path.join(mirror, "a.txt")) == "one\ntwo\nthree\n"
      assert sha(mirror, "HEAD") == sha(repo, "master")
      assert git(mirror, ["branch", "--show-current"]) == "master\n"
      assert sha(mirror, "host") == sha(repo, "master")

      assert %{"app" => %{error: nil, default: "master", rescued: nil}} =
               Sandbox.snapshot(username).mirror

      assert {:error, {:not_a_repository, _}} = Projects.open(username, base)
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
      {:ok, _} = Projects.open(username, repo)
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
      {:ok, _} = Projects.open(username, repo)
      vm = %{name: "vm", status: :running, started_at: nil}
      %{projects: projects, mirror: entries} = Sandbox.snapshot(username)
      entries = Map.new(entries, fn {name, entry} -> {name, %{entry | vm_started_at: nil}} end)

      # Nothing moved: a stray file stays where it is.
      File.write!(Path.join(mirror, "stray.txt"), "x\n")
      shares = Sandbox.snapshot(username).settings.shares
      :ok = Projects.follow(username, projects, entries, vm, 60, shares)
      assert File.exists?(Path.join(mirror, "stray.txt"))

      commit(repo, [{"b.txt", "yours\n"}], "second")
      :ok = Projects.follow(username, projects, entries, vm, 60, shares)
      refute File.exists?(Path.join(mirror, "stray.txt"))
      assert sha(mirror, "HEAD") == sha(repo, "master")
      assert Mirror.tips(hd(projects)) == %{"master" => sha(repo, "master")}
    end

    test "its settings choose the target branches, and the mirror has each", %{
      username: username,
      repo: repo,
      mirror: mirror
    } do
      {:ok, _} = Projects.open(username, repo)
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

      assert :ok = Projects.forget(username, "app")
      assert Projects.list(username) == []
    end
  end

  describe "an agent" do
    test "starts its task in a worktree slot, and is told where it is", %{
      username: username,
      repo: repo,
      mirror: mirror
    } do
      {:ok, _} = Projects.open(username, repo)

      assert {0, made} = Channel.answer("worktree", %{"cwd" => mirror, "name" => "fix"}, username)
      tree = Path.join(mirror <> ".wt", "slot-1")

      assert made =~
               "Started the task fix in slot-1, #{tree}: a new branch from the user's master."

      assert made =~ "zed ssh://mdt-sandbox#{tree}"
      assert git(tree, ["branch", "--show-current"]) == "fix\n"

      assert {1, taken} =
               Channel.answer("worktree", %{"cwd" => mirror, "name" => "fix"}, username)

      assert taken =~ "There is a branch fix already" and taken =~ "mdt worktree resume fix"

      assert {1, bad} =
               Channel.answer(
                 "worktree",
                 %{"cwd" => mirror, "name" => "-x", "onto" => "x"},
                 username
               )

      assert bad =~ "isn't a target branch"

      assert {1, bad_name} =
               Channel.answer("worktree", %{"cwd" => mirror, "name" => "-x"}, username)

      assert bad_name =~ "can't be a branch name"

      assert {0, here} = Channel.answer("project", %{"cwd" => mirror}, username)
      assert here =~ "You are in the mirror" and here =~ "view only"
      assert here =~ "slot-1  fix, no handoff yet"
      assert here =~ "slot-3  free, not made yet"

      assert {0, there} = Channel.answer("project", %{"cwd" => tree}, username)
      assert there =~ "You are in slot-1, #{tree}, on the task branch fix"
      assert there =~ "slot-1  fix, no handoff yet  (here)"

      assert {:ok, %{slots: [%{name: "slot-1", branch: "fix", free?: false}, _, _], others: []}} =
               Projects.slots(username, "app")

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
      assert listed =~ "#1  open, waiting for the user (this branch)"
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

  describe "worktree slots" do
    setup %{username: username, repo: repo} do
      # The build's output, which git ignores, is what a slot keeps warm.
      commit(repo, [{".gitignore", "_build/\n"}], "ignore the build")
      {:ok, _} = Projects.open(username, repo)
      :ok
    end

    defp slot(mirror, n), do: Path.join(mirror <> ".wt", "slot-#{n}")

    defp worktree(username, cwd, action, fields \\ %{}),
      do:
        Channel.answer(
          "worktree",
          Map.merge(%{"cwd" => cwd, "action" => action}, fields),
          username
        )

    defp states(username) do
      {:ok, %{slots: slots}} = Projects.slots(username, "app")
      Enum.map(slots, &{&1.name, &1.branch, &1.free?})
    end

    test "a task gets its own branch in a slot that keeps what git ignores", %{
      username: username,
      repo: repo,
      mirror: mirror
    } do
      {0, _} = worktree(username, mirror, "new", %{"name" => "fix"})
      one = slot(mirror, 1)
      File.mkdir_p!(Path.join(one, "_build"))
      File.write!(Path.join(one, "_build/app.beam"), "warm\n")
      commit(one, [{"a.txt", "one\ntwo\nthree\nfour\n"}], "the fix")
      {0, _} = Channel.answer("handoff", ask(one), username)

      # Busy while its handoff is open: the next task takes the next slot.
      {0, second} = worktree(username, mirror, "new", %{"name" => "cart"})
      assert second =~ "in slot-2, #{slot(mirror, 2)}"

      assert [{"slot-1", "fix", false}, {"slot-2", "cart", false}, {"slot-3", nil, true}] =
               states(username)

      # Accepted: slot-1 is free without anyone touching it, and the next
      # task takes it, on a new branch from your branch as it is now.
      {:ok, _} = Handoffs.accept(username, 1, :commits)
      {:ok, _} = Projects.mirror(username, "app")
      assert [{"slot-1", "fix", true} | _] = states(username)

      {0, third} = worktree(username, mirror, "new", %{"name" => "docs"})
      assert third =~ "Started the task docs in slot-1"
      assert git(one, ["branch", "--show-current"]) == "docs\n"
      assert sha(one, "HEAD") == sha(repo, "master")
      assert File.read!(Path.join(one, "_build/app.beam")) == "warm\n"

      # The handoff's branch stays, with its commits.
      assert git(mirror, ["log", "-1", "--format=%s", "fix"]) == "the fix\n"
    end

    test "a slot is locked, so git worktree remove leaves it; one whose folder went is made again",
         %{username: username, mirror: mirror} do
      {0, _} = worktree(username, mirror, "new", %{"name" => "fix"})
      one = slot(mirror, 1)

      assert git(mirror, ["worktree", "list", "--porcelain"]) =~ "locked MDT worktree slot"

      # What Zed's worktree picker and thread archive run.
      assert {_, status} =
               System.cmd("git", ["-C", mirror, "worktree", "remove", "--force", one],
                 env: Guest.git_env(),
                 stderr_to_stdout: true
               )

      assert status != 0
      assert File.dir?(one)

      # Its folder deleted anyway: the slot is free, its branch stays, and
      # the next task makes the folder again.
      File.rm_rf!(one)
      assert [{"slot-1", "fix", true} | _] = states(username)
      assert {0, free} = worktree(username, mirror, "free", %{"slot" => "1"})
      assert free =~ "slot-1 is free already: free, its folder is gone (the branch fix stays)"
      {0, made} = worktree(username, mirror, "new", %{"name" => "again"})
      assert made =~ "in slot-1"
      assert git(one, ["branch", "--show-current"]) == "again\n"
      assert git(mirror, ["branch", "--list", "fix"]) =~ "fix"
    end

    test "uncommitted work is never switched away", %{username: username, mirror: mirror} do
      {0, _} = worktree(username, mirror, "new", %{"name" => "fix"})
      one = slot(mirror, 1)
      File.write!(Path.join(one, "notes.txt"), "not committed\n")

      assert {1, refused} = worktree(username, one, "free")
      assert refused =~ "slot-1 has uncommitted work (fix)"

      assert {1, busy} = worktree(username, mirror, "new", %{"name" => "cart", "slot" => "1"})
      assert busy =~ "slot-1 has uncommitted work"

      assert {1, nope} = worktree(username, mirror, "new", %{"name" => "cart", "slot" => "7"})
      assert nope =~ "There is no slot slot-7: the project has 3"

      assert git(one, ["branch", "--show-current"]) == "fix\n"
      assert File.read!(Path.join(one, "notes.txt")) == "not committed\n"
    end

    test "with none free, the agent is told what each holds", %{
      username: username,
      mirror: mirror
    } do
      {:ok, _} = Projects.update(username, "app", %{"slots" => "1"})
      {0, _} = worktree(username, mirror, "new", %{"name" => "fix"})

      assert {1, full} = worktree(username, mirror, "new", %{"name" => "cart"})
      assert full =~ "No slot is free:\n  slot-1: fix, no handoff yet"
      assert full =~ "mdt worktree free SLOT"

      assert {:error, :bad_slots} = Projects.update(username, "app", %{"slots" => "0"})
      assert {:error, :bad_slots} = Projects.update(username, "app", %{"slots" => "x"})
    end

    test "freed, a slot goes off its branch, and a new task from it stays there", %{
      username: username,
      mirror: mirror
    } do
      {0, _} = worktree(username, mirror, "new", %{"name" => "fix"})
      {0, _} = worktree(username, mirror, "new", %{"name" => "cart"})
      two = slot(mirror, 2)
      commit(two, [{"c.txt", "cart\n"}], "the cart")

      assert {0, freed} = worktree(username, mirror, "free", %{"slot" => "slot-2"})
      assert freed =~ "Freed slot-2" and freed =~ "The branch cart stays, with its commits."
      assert freed =~ "It has no handoff."
      assert git(two, ["branch", "--show-current"]) == ""
      assert {0, again} = worktree(username, two, "free")
      assert again =~ "slot-2 is free already"

      # slot-1 is busy; the agent in slot-2 starts its next task where it is.
      {0, next} = worktree(username, two, "new", %{"name" => "next"})
      assert next =~ "Started the task next in slot-2"
      assert next =~ "You are in it: continue here."
      assert git(mirror, ["log", "-1", "--format=%s", "cart"]) == "the cart\n"

      assert {1, not_slot} = worktree(username, mirror, "free")
      assert not_slot =~ "This folder isn't a slot"
    end

    test "a handoff sent back after its slot went to another task resumes in a free slot", %{
      username: username,
      repo: repo,
      mirror: mirror
    } do
      {0, _} = worktree(username, mirror, "new", %{"name" => "fix"})
      one = slot(mirror, 1)
      commit(one, [{"a.txt", "one\ntwo\nthree\nfour\n"}], "the fix")
      {0, _} = Channel.answer("handoff", ask(one), username)

      # Freed while the user looks at it, then taken by another task.
      {0, _} = worktree(username, one, "free")
      {0, _} = worktree(username, one, "new", %{"name" => "other"})
      {:ok, _} = Handoffs.send_back(username, 1, "Add a test.")

      assert {0, listed} = Channel.answer("handoffs", %{"cwd" => one}, username)
      assert listed =~ "sent back to you"
      assert listed =~ "Its branch is in no worktree now. To continue it: mdt worktree resume fix"
      refute listed =~ "(this branch)"

      assert {1, no_branch} = worktree(username, one, "resume", %{"name" => "nope"})
      assert no_branch =~ "There is no branch nope"
      assert {1, target} = worktree(username, one, "resume", %{"name" => "master"})
      assert target =~ "one of the user's target branches"
      assert {0, held} = worktree(username, mirror, "resume", %{"name" => "other"})
      assert held =~ "other is in slot-1 already"

      # The busy slot stays as it is; the branch goes to a free one.
      assert {0, resumed} = worktree(username, one, "resume", %{"name" => "fix"})
      two = slot(mirror, 2)
      assert resumed =~ "Put the branch fix, as it was, in slot-2, #{two}"
      assert resumed =~ "zed ssh://mdt-sandbox#{two}"
      assert git(one, ["branch", "--show-current"]) == "other\n"
      assert git(two, ["branch", "--show-current"]) == "fix\n"

      assert {0, already} = worktree(username, mirror, "resume", %{"name" => "fix"})
      assert already =~ "fix is in slot-2 already"

      assert {0, listed} = Channel.answer("handoffs", %{"cwd" => two}, username)
      assert listed =~ "#1  sent back to you (this branch)"
      assert listed =~ "In slot-2, #{two}."

      # Its next revision comes from the new slot.
      commit(two, [{"t.txt", "test\n"}], "a test")
      {0, said} = Channel.answer("handoff", %{"cwd" => two}, username)
      assert said =~ "Updated handoff #1 (revision 2)"
      assert [%Handoff{source: %{top: ^two, branch: "fix"}, status: :open}] = handoffs(username)
      assert sha(repo, "master") != sha(two, "HEAD")
    end

    test "a per-task worktree made before slots keeps working beside them", %{
      username: username,
      mirror: mirror,
      vm: vm
    } do
      old = Path.join(vm, "app.wt/push-options")

      git(mirror, [
        "worktree",
        "add",
        "-q",
        "--no-track",
        "-b",
        "push-options",
        old,
        "host/master"
      ])

      assert {0, there} = Channel.answer("project", %{"cwd" => old}, username)
      assert there =~ "You are in the worktree #{old}"

      assert {:ok, %{others: [%{path: ^old, branch: "push-options"}]}} =
               Projects.slots(username, "app")

      commit(old, [{"p.txt", "push\n"}], "push options")
      assert {0, said} = Channel.answer("handoff", ask(old), username)
      assert said =~ "Handed off as #1: push-options onto the user's master."

      # It can't be resumed into a slot while it is checked out there.
      assert {1, held} = worktree(username, mirror, "resume", %{"name" => "push-options"})
      assert held =~ "push-options is checked out in #{old}: continue it there."
    end
  end
end
