defmodule MDTClientWeb.SandboxProjectsLiveTest do
  # The folder standing in for the VM is application config, so these tests
  # take turns.
  use MDTClientWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias MDTClient.Sandbox
  alias MDTClient.Sandbox.{Channel, Guest, Project, Projects}

  @me [
    {"GIT_AUTHOR_NAME", "Someone"},
    {"GIT_AUTHOR_EMAIL", "someone@example.test"},
    {"GIT_COMMITTER_NAME", "Someone"},
    {"GIT_COMMITTER_EMAIL", "someone@example.test"}
  ]

  defp git(dir, args) do
    {output, 0} =
      System.cmd("git", ["-C", dir | args], env: @me ++ Guest.git_env(), stderr_to_stdout: true)

    output
  end

  setup %{conn: conn} do
    context = sign_in(conn)
    base = Path.join(System.tmp_dir!(), "projects-live-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(base) end)

    repo = Path.join(base, "app")
    File.mkdir_p!(repo)
    git(repo, ["init", "-q", "-b", "master"])
    File.write!(Path.join(repo, "a.txt"), "one\ntwo\nthree\n")
    File.write!(Path.join(repo, "mix.exs"), "# the build\n")
    git(repo, ["add", "--all"])
    git(repo, ["commit", "-q", "-m", "first"])

    vm = Path.join(base, "vm")
    File.mkdir_p!(vm)
    guest = Guest.local(vm)
    Application.put_env(:mdt_client, Projects, guest: guest)
    on_exit(fn -> Application.delete_env(:mdt_client, Projects) end)

    Map.merge(context, %{repo: repo, guest: guest})
  end

  # An agent's handoff: a worktree with one commit, then `mdt handoff`.
  defp hand_off(username, guest, task, title, change) do
    [project] = Sandbox.snapshot(username).settings.projects
    copy = Project.guest_path(project, guest)
    tree = Path.join(Project.worktrees_path(project, guest), task)
    git(copy, ["worktree", "add", "-q", "-b", task, tree, "host/master"])
    change.(tree)
    git(tree, ["add", "--all"])
    git(tree, ["commit", "-q", "-m", "work on #{task}"])

    {0, _} =
      Channel.answer(
        "handoff",
        %{"cwd" => tree, "title" => title, "body" => "Done, with tests.", "agent" => "claude"},
        username
      )

    [handoff | _] = Sandbox.snapshot(username).handoffs
    handoff
  end

  test "a repository is added, synced and removed", %{conn: conn, username: username, repo: repo} do
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/projects")
    assert has_element?(view, "#project-list", "No project yet")

    view |> form("#project-form", project: %{path: Path.join(repo, "nope")}) |> render_submit()
    assert has_element?(view, "#project-error", "That folder does not exist.")

    view |> form("#project-form", project: %{path: repo}) |> render_submit()
    assert has_element?(view, "#project-app", repo)
    assert has_element?(view, "#project-app", "not synced yet")
    assert has_element?(view, "#notices", "app is a project")

    view |> form("#project-sync-app") |> render_submit()
    assert has_element?(view, "#notices", "app synced into the VM")
    assert has_element?(view, "#project-app", "synced")
    assert [%{synced_at: %DateTime{}}] = Sandbox.snapshot(username).settings.projects

    view |> element("#project-remove-app") |> render_click()
    refute has_element?(view, "#project-app")
    assert Sandbox.snapshot(username).settings.projects == []
  end

  test "a handoff made to break or mislead the page is shown with all it holds",
       %{conn: conn, username: username, repo: repo, guest: guest} do
    {:ok, _} = Projects.add(username, repo)
    {:ok, _} = Projects.sync(username, "app")
    turn = <<0x202E::utf8>>

    handoff =
      hand_off(username, guest, "odd", "Tidy " <> turn <> "eteled", fn tree ->
        File.write!(Path.join(tree, <<"caf", 0xE9, ".txt">>), "a name that isn't UTF-8\n")
        File.write!(Path.join(tree, "safe" <> turn <> "txt.sh"), "echo hi\n")
        File.write!(Path.join(tree, "a.txt"), <<"one\n", 0xFF, 0xFE, " two\e[2J\nthree\n">>)
      end)

    {:ok, view, html} = live(conn, ~p"/tools/sandbox/projects?handoff=#{handoff.id}")

    # What the page is sent as: JSON, which takes UTF-8 only.
    assert String.valid?(html)
    assert {:ok, _} = Jason.encode(render(view))
    assert has_element?(view, "#handoff-row-#{handoff.id}", "Tidy \\u{202E}eteled")
    assert has_element?(view, "#handoff-facts", "3 files")
    assert has_element?(view, "#handoff-diff-text", "\\u{1B}[2J")
    refute render(view) =~ turn
  end

  test "a handoff is shown with the agent's words apart from the facts, and brought in whole",
       %{conn: conn, username: username, repo: repo, guest: guest} do
    {:ok, _} = Projects.add(username, repo)
    {:ok, _} = Projects.sync(username, "app")

    handoff =
      hand_off(username, guest, "fix", "Fix the login", fn tree ->
        File.write!(Path.join(tree, "a.txt"), "one\ntwo, from the vm\nthree\n")
        File.write!(Path.join(tree, "mix.exs"), "# the build, changed\n")
      end)

    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/projects")
    assert has_element?(view, "#handoff-row-#{handoff.id}", "Fix the login")
    assert has_element?(view, "#handoff-none")

    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/projects?handoff=#{handoff.id}")
    assert has_element?(view, "#handoff-claims", "Done, with tests.")
    assert has_element?(view, "#handoff-claims", "work on fix")
    assert has_element?(view, "#handoff-facts", "1 commit")
    assert has_element?(view, "#handoff-facts", "2 files")
    assert has_element?(view, "#handoff-merges")
    assert has_element?(view, "#handoff-hints", "mix.exs, which runs when you build")
    assert has_element?(view, "#handoff-files", "a.txt")
    assert has_element?(view, "#handoff-diff-text", "two, from the vm")

    head = git(repo, ["rev-parse", "HEAD"])
    view |> element("#handoff-bring") |> render_click()
    assert has_element?(view, "#notices", "In your working tree, uncommitted")
    assert has_element?(view, "#handoff-undo")
    assert git(repo, ["status", "--porcelain"]) == " M a.txt\n M mix.exs\n"
    assert git(repo, ["rev-parse", "HEAD"]) == head

    view |> element("#handoff-undo") |> render_click()
    assert has_element?(view, "#handoff-bring")
    assert git(repo, ["status", "--porcelain"]) == ""
  end

  test "a handoff that doesn't merge can't be brought in by accident; it is sent back with a note",
       %{conn: conn, username: username, repo: repo, guest: guest} do
    {:ok, _} = Projects.add(username, repo)
    {:ok, _} = Projects.sync(username, "app")

    handoff =
      hand_off(username, guest, "fix", "Fix it", fn tree ->
        File.write!(Path.join(tree, "a.txt"), "one\ntwo, from the vm\nthree\n")
      end)

    File.write!(Path.join(repo, "a.txt"), "one\ntwo, mine\nthree\n")

    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/projects?handoff=#{handoff.id}")
    assert has_element?(view, "#handoff-conflicts", "a.txt")
    assert has_element?(view, "#handoff-bring[disabled]")
    assert has_element?(view, "#handoff-bring-anyway[data-confirm]")

    view
    |> form("#handoff-send-back", send_back: %{note: "Bring it up to date with my branch."})
    |> render_submit()

    assert has_element?(view, "#notices", "Sent back to the agent")
    refute has_element?(view, "#handoff-bring")
    assert has_element?(view, "#handoff-actions", "Bring it up to date with my branch.")
    assert File.read!(Path.join(repo, "a.txt")) == "one\ntwo, mine\nthree\n"

    assert [%{status: :sent_back, note: "Bring it up to date with my branch."}] =
             Sandbox.snapshot(username).handoffs
  end

  test "with the VM stopped, the page says so and Sync is off", %{
    conn: conn,
    username: username,
    repo: repo
  } do
    {:ok, _} = Projects.add(username, repo)

    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/projects")
    assert has_element?(view, "#projects-vm-off")
    assert has_element?(view, "#project-sync-button-app[disabled]")
  end
end
