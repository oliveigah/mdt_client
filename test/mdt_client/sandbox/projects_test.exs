defmodule MDTClient.Sandbox.ProjectsTest do
  @moduledoc """
  A project end to end with git alone: your repository, its copy "in the
  VM" (a folder of this machine in its place), a sync one way and a handoff
  back. What only a real VM adds, the pipe git speaks through, is in
  `vm_live_test.exs`.
  """
  use ExUnit.Case, async: true

  alias MDTClient.Sandbox.{Guest, Handoff, HostGit, Project, Sync}

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

  defp lines(count, word), do: Enum.map_join(1..count, &"#{word} line #{&1}\n")

  # What must never change on your side unless you asked: where HEAD is,
  # what is staged, and which branches exist.
  defp yours(repo) do
    {git(repo, ["rev-parse", "HEAD"]), git(repo, ["write-tree"]),
     git(repo, ["for-each-ref", "refs/heads"])}
  end

  setup do
    base = Path.join(System.tmp_dir!(), "projects-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(base) end)
    repo = Path.join(base, "host/my app")
    File.mkdir_p!(repo)
    git(repo, ["init", "-q", "-b", "master"])
    File.write!(Path.join(repo, "a.txt"), lines(10, "a"))
    File.write!(Path.join(repo, "mix.exs"), "# the build\n")
    File.write!(Path.join(repo, "gone.txt"), "to be deleted\n")
    File.write!(Path.join(repo, ".gitignore"), "_build/\n.env\n")
    git(repo, ["add", "--all"])
    git(repo, ["commit", "-q", "-m", "first"])

    vm = Path.join(base, "vm/work")
    File.mkdir_p!(vm)
    {:ok, project} = Project.new(repo, [])
    %{base: base, repo: repo, guest: Guest.local(vm), project: project}
  end

  # An agent's session: a worktree and a branch of its own, from your branch.
  defp worktree(project, guest, task) do
    copy = Project.guest_path(project, guest)
    tree = Path.join(Project.worktrees_path(project, guest), task)
    git(copy, ["worktree", "add", "-q", "-b", task, tree, "host/master"])
    tree
  end

  describe "a project" do
    test "is the top folder of a repository with a commit, named for the VM", %{
      base: base,
      repo: repo,
      project: project
    } do
      assert %Project{name: "my-app", path: ^repo} = project

      assert {:ok, %Project{name: "my-app-2"}} =
               Project.new(repo, [%{project | path: "/elsewhere"}])

      assert Project.new(repo, [project]) == {:error, :already_added}
      assert Project.new(Path.join(base, "nope"), []) == {:error, :not_a_folder}
      assert Project.new(base, []) == {:error, :not_a_repository}

      File.mkdir_p!(Path.join(repo, "sub"))
      assert Project.new(Path.join(repo, "sub"), []) == {:error, :not_its_top}

      empty = Path.join(base, "empty")
      File.mkdir_p!(empty)
      git(empty, ["init", "-q"])
      assert Project.new(empty, []) == {:error, :no_commit}
      assert Project.explain(:not_its_top) =~ "top folder"
    end

    test "is found from its copy and from a worktree beside it", %{project: project, guest: guest} do
      root = guest.root

      assert Project.of([project], guest, Path.join(root, "my-app")) == project
      assert Project.of([project], guest, Path.join(root, "my-app/lib")) == project
      assert Project.of([project], guest, Path.join(root, "my-app.wt/fix/lib")) == project
      assert Project.of([project], guest, Path.join(root, "my-app-other")) == nil
      assert Project.of([project], guest, "/tmp") == nil
    end
  end

  describe "sync, your work into the VM" do
    test "the first one makes the copy, on your branch, with your branches as host/…", %{
      repo: repo,
      guest: guest,
      project: project
    } do
      git(repo, ["branch", "side"])
      before = yours(repo)

      assert {:ok, %{branch: "master", followed: :updated, uncommitted: false}} =
               Sync.run(project, guest)

      copy = Project.guest_path(project, guest)
      assert File.read!(Path.join(copy, "a.txt")) == lines(10, "a")
      assert git(copy, ["symbolic-ref", "--short", "HEAD"]) == "master\n"

      assert git(copy, ["for-each-ref", "--format=%(refname)", "refs/remotes"]) ==
               "refs/remotes/host/master\nrefs/remotes/host/side\n"

      # A sync writes nothing on your side.
      assert yours(repo) == before
      assert git(repo, ["for-each-ref", "refs/remotes"]) == ""
    end

    test "the copy follows your branch while it is clean and only behind", %{
      repo: repo,
      guest: guest,
      project: project
    } do
      {:ok, _} = Sync.run(project, guest)
      copy = Project.guest_path(project, guest)

      assert {:ok, %{followed: :current}} = Sync.run(project, guest)

      File.write!(Path.join(repo, "a.txt"), lines(10, "a") <> "more\n")
      git(repo, ["commit", "-q", "-am", "second"])
      assert {:ok, %{followed: :updated}} = Sync.run(project, guest)
      assert File.read!(Path.join(copy, "a.txt")) =~ "more"

      # Changes of its own, not committed: left alone, but host/master moves.
      File.write!(Path.join(copy, "a.txt"), "the vm's edit\n")
      File.write!(Path.join(repo, "a.txt"), lines(10, "a") <> "more\nand more\n")
      git(repo, ["commit", "-q", "-am", "third"])

      assert {:ok, %{followed: {:left, "It has changes that aren't committed."}}} =
               Sync.run(project, guest)

      assert File.read!(Path.join(copy, "a.txt")) == "the vm's edit\n"
      assert git(copy, ["rev-parse", "host/master"]) == git(repo, ["rev-parse", "master"])

      # Commits of its own: left alone too.
      git(copy, ["commit", "-q", "-am", "the vm's own commit"])
      File.write!(Path.join(repo, "mix.exs"), "# changed\n")
      git(repo, ["commit", "-q", "-am", "fourth"])
      assert {:ok, %{followed: {:left, "It has commits of its own."}}} = Sync.run(project, guest)
      assert git(copy, ["rev-parse", "host/master"]) == git(repo, ["rev-parse", "master"])
    end

    test "what you haven't committed goes only when you ask, and nothing of yours changes", %{
      repo: repo,
      guest: guest,
      project: project
    } do
      File.write!(Path.join(repo, "a.txt"), lines(10, "a") <> "not committed\n")
      File.write!(Path.join(repo, "new.txt"), "a new file\n")
      File.mkdir_p!(Path.join(repo, "_build"))
      File.write!(Path.join(repo, "_build/out"), "ignored\n")
      git(repo, ["add", "new.txt"])
      before = {yours(repo), git(repo, ["status", "--porcelain", "--ignored"])}
      copy = Project.guest_path(project, guest)

      assert {:ok, %{uncommitted: false}} = Sync.run(project, guest)
      refute File.exists?(Path.join(copy, "new.txt"))
      assert git(copy, ["for-each-ref", "refs/remotes/host-wip"]) == ""

      assert {:ok, %{uncommitted: true}} = Sync.run(project, guest, uncommitted: true)
      assert git(copy, ["show", "host-wip/master:a.txt"]) =~ "not committed"
      assert git(copy, ["show", "host-wip/master:new.txt"]) == "a new file\n"
      assert git(copy, ["ls-tree", "-r", "--name-only", "host-wip/master"]) =~ "new.txt"
      refute git(copy, ["ls-tree", "-r", "--name-only", "host-wip/master"]) =~ "_build"

      assert {yours(repo), git(repo, ["status", "--porcelain", "--ignored"])} == before
    end
  end

  describe "a handoff, the VM's work back to you" do
    setup %{repo: repo, guest: guest, project: project} do
      {:ok, _} = Sync.run(project, guest)
      tree = worktree(project, guest, "fix-login")

      File.write!(
        Path.join(tree, "a.txt"),
        String.replace(lines(10, "a"), "a line 2\n", "a line 2, from the vm\n")
      )

      File.write!(Path.join(tree, "mix.exs"), "# the build, changed\n")
      File.mkdir_p!(Path.join(tree, "lib/deep"))
      File.write!(Path.join(tree, "lib/deep/new.ex"), "a new file\n")
      git(tree, ["rm", "-q", "gone.txt"])
      git(tree, ["add", "--all"])
      git(tree, ["commit", "-q", "-m", "fix the login"])

      File.write!(
        Path.join(tree, "a.txt"),
        File.read!(Path.join(tree, "a.txt")) <> "a second commit\n"
      )

      git(tree, ["commit", "-q", "-am", "and its test"])

      ask = %{cwd: tree, title: "Fix the login", body: "It dropped the path.", agent: "claude"}

      %{
        tree: tree,
        ask: ask,
        tip: String.trim(git(tree, ["rev-parse", "HEAD"])),
        head: String.trim(git(repo, ["rev-parse", "HEAD"]))
      }
    end

    test "is the worktree's branch as it is then, fixed to one commit", context do
      %{repo: repo, guest: guest, project: project, tree: tree, ask: ask, tip: tip, head: head} =
        context

      before = yours(repo)

      assert {:ok, %Handoff{} = handoff} = Handoff.receive(project, guest, ask)

      assert %{
               project: "my-app",
               branch: "fix-login",
               commit: ^tip,
               base: ^head,
               status: :waiting
             } = handoff

      assert %{title: "Fix the login", body: "It dropped the path.", agent: "claude"} = handoff
      assert git(repo, ["rev-parse", "refs/remotes/vm/fix-login"]) == tip <> "\n"
      # Kept like a remote's branch: not one of yours, and nothing of yours moved.
      assert yours(repo) == before

      # Later work in the VM doesn't change what you are looking at.
      File.write!(Path.join(tree, "later.txt"), "later\n")
      git(tree, ["add", "--all"])
      git(tree, ["commit", "-q", "-m", "later"])
      assert git(repo, ["rev-parse", "refs/remotes/vm/fix-login"]) == tip <> "\n"
    end

    test "is refused from the copy itself, with uncommitted work, or with no title", context do
      %{guest: guest, project: project, tree: tree, ask: ask, base: base} = context
      copy = Project.guest_path(project, guest)

      assert Handoff.receive(project, guest, %{ask | cwd: copy}) == {:error, :not_a_worktree}
      assert Handoff.receive(project, guest, %{ask | cwd: base}) == {:error, :not_in_a_project}

      assert Handoff.receive(project, guest, %{ask | cwd: "/no/such/folder"}) ==
               {:error, :not_in_a_project}

      assert Handoff.receive(project, guest, %{ask | title: "  "}) == {:error, :no_title}

      File.write!(Path.join(tree, "half.txt"), "half done\n")
      assert {:error, {:uncommitted, "?? half.txt"}} = Handoff.receive(project, guest, ask)
      assert Handoff.explain({:uncommitted, "?? half.txt"}) =~ "Commit or discard"
      File.rm!(Path.join(tree, "half.txt"))

      git(tree, ["checkout", "-q", "--detach"])
      assert Handoff.receive(project, guest, ask) == {:error, :detached}
    end

    test "the facts are MDT's: size, commits, what it merges with, what runs", context do
      %{repo: repo, guest: guest, project: project, ask: ask} = context
      {:ok, handoff} = Handoff.receive(project, guest, ask)

      facts = Handoff.facts(project, handoff)
      assert facts.commits == 2
      assert facts.messages == ["and its test", "fix the login"]

      assert Enum.map(facts.files, & &1.path) == [
               "a.txt",
               "gone.txt",
               "lib/deep/new.ex",
               "mix.exs"
             ]

      assert %{path: "lib/deep/new.ex", added: 1, removed: 0} in facts.files
      assert facts.added == 4 and facts.removed == 3
      assert facts.behind == 0
      assert facts.conflicts == []
      assert facts.hints == ["It changes mix.exs, which runs when you build."]

      # Your branch moves on, and you edit a line the handoff also edits.
      File.write!(Path.join(repo, "other.txt"), "mine\n")
      git(repo, ["add", "other.txt"])
      git(repo, ["commit", "-q", "-m", "mine"])

      File.write!(
        Path.join(repo, "a.txt"),
        String.replace(lines(10, "a"), "a line 2\n", "a line 2, mine\n")
      )

      assert %{behind: 1, conflicts: ["a.txt"]} = Handoff.facts(project, handoff)
      assert {:ok, diff} = Handoff.diff(project, handoff)
      assert diff =~ "+a line 2, from the vm"
    end

    test "comes into your working tree whole and uncommitted, and can be undone", context do
      %{repo: repo, guest: guest, project: project, ask: ask} = context
      {:ok, handoff} = Handoff.receive(project, guest, ask)

      # Your own work in progress: one change staged, one not.
      File.write!(Path.join(repo, "staged.txt"), "staged by me\n")
      git(repo, ["add", "staged.txt"])

      File.write!(
        Path.join(repo, "a.txt"),
        String.replace(lines(10, "a"), "a line 9\n", "a line 9, mine\n")
      )

      before = yours(repo)
      status = git(repo, ["status", "--porcelain"])

      assert {:ok, undo} = Handoff.bring(project, handoff)
      assert Enum.sort(undo.paths) == ["a.txt", "gone.txt", "lib/deep/new.ex", "mix.exs"]
      assert undo.created == ["lib/deep/new.ex"]

      # No commit, nothing staged or unstaged for you, no branch of yours touched.
      assert yours(repo) == before

      assert git(repo, ["status", "--porcelain"]) ==
               " M a.txt\n D gone.txt\n M mix.exs\nA  staged.txt\n?? lib/\n"

      merged = File.read!(Path.join(repo, "a.txt"))
      assert merged =~ "a line 2, from the vm" and merged =~ "a line 9, mine"
      assert File.read!(Path.join(repo, "lib/deep/new.ex")) == "a new file\n"

      assert :ok = Handoff.undo(project, undo)
      assert yours(repo) == before
      assert git(repo, ["status", "--porcelain"]) == status
      refute File.exists?(Path.join(repo, "lib"))
    end

    test "that doesn't merge writes nothing, unless you take it with its conflicts", context do
      %{repo: repo, guest: guest, project: project, ask: ask} = context
      {:ok, handoff} = Handoff.receive(project, guest, ask)

      File.write!(
        Path.join(repo, "a.txt"),
        String.replace(lines(10, "a"), "a line 2\n", "a line 2, mine\n")
      )

      status = git(repo, ["status", "--porcelain"])

      assert Handoff.bring(project, handoff) == {:error, {:conflicts, ["a.txt"]}}
      assert git(repo, ["status", "--porcelain"]) == status
      refute File.exists?(Path.join(repo, "lib/deep/new.ex"))

      assert {:ok, undo} = Handoff.bring(project, handoff, true)
      assert File.read!(Path.join(repo, "a.txt")) =~ "<<<<<<<"
      assert File.exists?(Path.join(repo, "lib/deep/new.ex"))
      assert :ok = Handoff.undo(project, undo)
      assert git(repo, ["status", "--porcelain"]) == status
    end

    test "never writes over a file of yours that git ignores", context do
      %{repo: repo, guest: guest, project: project, tree: tree, ask: ask} = context
      File.write!(Path.join(tree, ".env"), "FROM_THE_VM=1\n")
      git(tree, ["add", "--force", ".env"])
      git(tree, ["commit", "-q", "-m", "an env file"])
      {:ok, handoff} = Handoff.receive(project, guest, ask)
      File.write!(Path.join(repo, ".env"), "MY_SECRET=1\n")

      assert Handoff.bring(project, handoff) == {:error, {:in_the_way, [".env"]}}
      assert File.read!(Path.join(repo, ".env")) == "MY_SECRET=1\n"
      refute File.exists?(Path.join(repo, "lib/deep/new.ex"))
    end

    test "stops showing as vm/… when it stops waiting, and MDT keeps its commit until forgotten",
         context do
      %{repo: repo, guest: guest, project: project, tree: tree, ask: ask} = context
      {:ok, first} = Handoff.receive(project, guest, ask)
      File.write!(Path.join(tree, "more.txt"), "more\n")
      git(tree, ["add", "--all"])
      git(tree, ["commit", "-q", "-m", "more"])
      {:ok, second} = Handoff.receive(project, guest, ask)
      refute second.commit == first.commit

      # A newer handoff of the same branch moved vm/…: hiding the older one leaves it.
      assert :ok = Handoff.hide(project, first)
      assert git(repo, ["rev-parse", "refs/remotes/vm/fix-login"]) == second.commit <> "\n"

      assert :ok = Handoff.hide(project, second)
      assert git(repo, ["for-each-ref", "refs/remotes/vm"]) == ""
      assert git(repo, ["rev-parse", "refs/mdt/handoffs/#{second.id}"]) == second.commit <> "\n"

      assert :ok = Handoff.show(project, second)
      assert git(repo, ["rev-parse", "refs/remotes/vm/fix-login"]) == second.commit <> "\n"

      assert :ok = Handoff.forget(project, first)
      assert :ok = Handoff.forget(project, second)
      assert git(repo, ["for-each-ref", "refs/mdt"]) == ""
    end
  end

  test "your working tree as a commit: new files in, ignored ones out, nothing of yours touched",
       %{
         repo: repo
       } do
    head = String.trim(git(repo, ["rev-parse", "HEAD"]))
    assert HostGit.snapshot(repo) == {:ok, head}

    File.write!(Path.join(repo, "new.txt"), "new\n")
    File.write!(Path.join(repo, ".env"), "ignored\n")
    before = {yours(repo), git(repo, ["status", "--porcelain", "--ignored"])}

    assert {:ok, snapshot} = HostGit.snapshot(repo)
    refute snapshot == head
    assert git(repo, ["rev-parse", "#{snapshot}^"]) == head <> "\n"
    files = git(repo, ["ls-tree", "-r", "--name-only", snapshot])
    assert files =~ "new.txt"
    refute files =~ ".env"
    assert {yours(repo), git(repo, ["status", "--porcelain", "--ignored"])} == before
  end
end
