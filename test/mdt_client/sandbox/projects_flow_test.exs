defmodule MDTClient.Sandbox.ProjectsFlowTest do
  @moduledoc """
  Projects and handoffs through the sandbox of an unlocked identity, as the
  pages and the agent channel use them. A folder of this machine stands in
  for the VM's disk; `vm_live_test.exs` has the real one.
  """
  # The stand-in is application config, so these tests take turns.
  use ExUnit.Case, async: false

  alias MDTClient.Sandbox
  alias MDTClient.Sandbox.{Channel, Guest, Handoff, Project, Projects}

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

  setup do
    %{username: username} = MDTClient.VaultHelpers.unlocked_identity("projects")
    base = Path.join(System.tmp_dir!(), "flow-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(base) end)

    repo = Path.join(base, "app")
    File.mkdir_p!(repo)
    git(repo, ["init", "-q", "-b", "master"])
    File.write!(Path.join(repo, "a.txt"), "one\ntwo\nthree\n")
    git(repo, ["add", "--all"])
    git(repo, ["commit", "-q", "-m", "first"])

    vm = Path.join(base, "vm")
    File.mkdir_p!(vm)
    guest = Guest.local(vm)
    Application.put_env(:mdt_client, Projects, guest: guest)
    on_exit(fn -> Application.delete_env(:mdt_client, Projects) end)

    %{username: username, repo: repo, guest: guest}
  end

  # An agent's session in the VM: a worktree of its own with one commit.
  defp session(project, guest, task, file \\ "b.txt") do
    copy = Project.guest_path(project, guest)
    tree = Path.join(Project.worktrees_path(project, guest), task)
    git(copy, ["worktree", "add", "-q", "-b", task, tree, "host/master"])
    File.write!(Path.join(tree, file), "from #{task}\n")
    git(tree, ["add", "--all"])
    git(tree, ["commit", "-q", "-m", "work on #{task}"])
    tree
  end

  defp outcomes(username, outcome),
    do: for(%{outcome: ^outcome} = event <- Sandbox.events(username), do: event.summary)

  test "a repository becomes a project, is synced, and stops being one", %{
    username: username,
    repo: repo,
    guest: guest
  } do
    assert {:ok, %Project{name: "app", path: ^repo} = project} = Projects.add(username, repo)
    assert Projects.add(username, repo) == {:error, :already_added}
    assert Projects.add(username, Path.join(repo, "nope")) == {:error, :not_a_folder}
    assert [%Project{name: "app", synced_at: nil}] = Sandbox.snapshot(username).settings.projects

    assert {:ok, %{branch: "master", followed: :updated}} = Projects.sync(username, "app")

    assert File.read!(Path.join(Project.guest_path(project, guest), "a.txt")) ==
             "one\ntwo\nthree\n"

    assert [%Project{synced_at: %DateTime{}}] = Sandbox.snapshot(username).settings.projects
    assert Projects.sync(username, "other") == {:error, :not_found}

    assert outcomes(username, :project) == ["app synced into the VM", "app added as a project"]

    assert :ok = Projects.remove(username, "app")
    assert Sandbox.snapshot(username).settings.projects == []
    assert Projects.remove(username, "app") == {:error, :not_found}
  end

  test "without a running VM a sync and a handoff say so", %{username: username, repo: repo} do
    {:ok, _} = Projects.add(username, repo)
    Application.delete_env(:mdt_client, Projects)

    assert Projects.sync(username, "app") == {:error, :vm_not_running}

    assert {1, "The VM isn't running."} =
             Channel.answer("sync", %{"cwd" => "/work/app"}, username)
  end

  test "an agent syncs and hands off through the channel; you bring it in, undo, and send it back",
       %{username: username, repo: repo, guest: guest} do
    {:ok, project} = Projects.add(username, repo)
    {:ok, _} = Projects.sync(username, "app")
    tree = session(project, guest, "fix")

    # mdt sync, from the worktree: your new commit arrives as host/master.
    File.write!(Path.join(repo, "c.txt"), "yours\n")
    git(repo, ["add", "--all"])
    git(repo, ["commit", "-q", "-m", "second"])
    assert {0, words} = Channel.answer("sync", %{"cwd" => tree}, username)
    assert words =~ "host/master" and words =~ "was brought up to it"
    assert git(tree, ["rev-parse", "host/master"]) == git(repo, ["rev-parse", "master"])
    assert {1, outside} = Channel.answer("sync", %{"cwd" => "/tmp"}, username)
    assert outside =~ "isn't in a project"

    # mdt handoff, refused from the project's own folder, taken from the worktree.
    ask = %{"cwd" => tree, "title" => "The fix", "body" => "It works now.", "agent" => "claude"}
    copy = Project.guest_path(project, guest)
    assert {1, refused} = Channel.answer("handoff", %{ask | "cwd" => copy}, username)
    assert refused =~ "worktree of your own"

    assert {0, taken} = Channel.answer("handoff", ask, username)

    assert [%Handoff{id: id, status: :waiting, title: "The fix", agent: "claude"}] =
             Sandbox.snapshot(username).handoffs

    assert taken =~ "Handed off as #{id}"
    assert git(repo, ["rev-parse", "--abbrev-ref", "refs/remotes/vm/fix"]) == "vm/fix\n"
    assert outcomes(username, :handoff) == [~s(claude handed off "The fix" in app)]

    assert {0, list} = Channel.answer("handoffs", %{"cwd" => tree}, username)
    assert list =~ "#{id}  waiting for the user"

    # What you see, and what you do.
    assert {:ok, %{commits: 1, files: [%{path: "b.txt"}], behind: 1, conflicts: []}} =
             Projects.facts(username, id)

    assert {:ok, diff} = Projects.diff(username, id)
    assert diff =~ "+from fix"

    head = git(repo, ["rev-parse", "HEAD"])

    assert {:ok, %Handoff{status: :brought, undo: %{created: ["b.txt"]}}} =
             Projects.bring(username, id)

    assert git(repo, ["status", "--porcelain"]) == "?? b.txt\n"
    assert git(repo, ["rev-parse", "HEAD"]) == head
    # It stopped waiting, so vm/fix is gone; MDT still holds the commit for undo.
    assert git(repo, ["for-each-ref", "refs/remotes/vm"]) == ""
    assert Projects.bring(username, id) == {:error, :not_waiting}

    assert {:ok, %Handoff{status: :waiting, undo: nil}} = Projects.undo(username, id)
    assert git(repo, ["status", "--porcelain"]) == ""
    assert git(repo, ["rev-parse", "--abbrev-ref", "refs/remotes/vm/fix"]) == "vm/fix\n"
    assert Projects.undo(username, id) == {:error, :nothing_to_undo}

    assert {:ok, %Handoff{status: :sent_back, note: "Add a test."}} =
             Projects.send_back(username, id, " Add a test. ")

    assert git(repo, ["for-each-ref", "refs/remotes/vm", "refs/mdt"]) == ""
    assert {0, list} = Channel.answer("handoffs", %{"cwd" => tree}, username)
    assert list =~ "#{id}  sent back" and list =~ "The user's note: Add a test."
    assert Projects.decline(username, id) == {:error, :not_waiting}
  end

  test "a later handoff of a branch replaces the one waiting; sessions keep to their own", %{
    username: username,
    repo: repo,
    guest: guest
  } do
    {:ok, project} = Projects.add(username, repo)
    {:ok, _} = Projects.sync(username, "app")
    one = session(project, guest, "one", "one.txt")
    two = session(project, guest, "two", "two.txt")

    assert {0, _} = Channel.answer("handoff", %{"cwd" => one, "title" => "One"}, username)
    assert {0, _} = Channel.answer("handoff", %{"cwd" => two, "title" => "Two"}, username)
    File.write!(Path.join(one, "more.txt"), "more\n")
    git(one, ["add", "--all"])
    git(one, ["commit", "-q", "-m", "more"])
    assert {0, _} = Channel.answer("handoff", %{"cwd" => one, "title" => "One, again"}, username)

    assert [
             %Handoff{title: "One, again", status: :waiting, branch: "one"} = again,
             %Handoff{title: "One", status: :replaced},
             %Handoff{title: "Two", status: :waiting, branch: "two"} = second
           ] = Sandbox.snapshot(username).handoffs

    # Each holds one session's work and nothing else.
    assert {:ok, %{files: [%{path: "more.txt"}, %{path: "one.txt"}]}} =
             Projects.facts(username, again.id)

    assert {:ok, %{files: [%{path: "two.txt"}]}} = Projects.facts(username, second.id)

    assert {:ok, %Handoff{status: :declined}} = Projects.decline(username, second.id)

    assert git(repo, ["for-each-ref", "--format=%(refname:short)", "refs/remotes/vm"]) ==
             "vm/one\n"

    # Removing the project lets go of everything it kept in your repository.
    assert :ok = Projects.remove(username, "app")
    assert git(repo, ["for-each-ref", "refs/remotes/vm", "refs/mdt"]) == ""
    assert Sandbox.snapshot(username).handoffs == []
  end

  test "the mdt command asks for a sync and a handoff with the folder it runs in", %{
    username: username,
    repo: repo,
    guest: guest
  } do
    if System.find_executable("socat") do
      {:ok, project} = Projects.add(username, repo)
      {:ok, _} = Projects.sync(username, "app")
      tree = session(project, guest, "cli")
      cli = Path.join([:code.priv_dir(:mdt_client), "sandbox", "mdt-cli"])

      env = [
        {"MDT_CHANNEL", "UNIX-CONNECT:" <> Channel.socket_path(username)},
        {"MDT_AGENT", "tester"}
      ]

      assert {synced, 0} =
               System.cmd("bash", [cli, "sync"], cd: tree, env: env, stderr_to_stdout: true)

      assert synced =~ "Synced app"

      body = Path.join(tree, "../body.md")
      File.write!(body, "Two lines\nof description.\n")

      assert {handed, 0} =
               System.cmd("bash", [cli, "handoff", "--title", "From the command", "--body", body],
                 cd: tree,
                 env: env,
                 stderr_to_stdout: true
               )

      assert handed =~ "Handed off as"

      assert [
               %Handoff{
                 title: "From the command",
                 body: "Two lines\nof description.",
                 agent: "tester"
               }
             ] =
               Sandbox.snapshot(username).handoffs

      assert {_, 1} =
               System.cmd("bash", [cli, "handoff"], cd: tree, env: env, stderr_to_stdout: true)

      assert {list, 0} =
               System.cmd("bash", [cli, "handoffs"], cd: tree, env: env, stderr_to_stdout: true)

      assert list =~ "waiting for the user"
    end
  end
end
