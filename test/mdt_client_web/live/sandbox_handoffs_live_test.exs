defmodule MDTClientWeb.SandboxHandoffsLiveTest do
  # The folder standing in for the VM is application config, so these tests
  # take turns.
  use MDTClientWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias MDTClient.Sandbox
  alias MDTClient.Sandbox.{Channel, Guest, Handoffs, Projects}

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
    base = Path.join(System.tmp_dir!(), "handoffs-live-#{System.unique_integer([:positive])}")
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
    Application.put_env(:mdt_client, Projects, guest: Guest.local(vm))
    Application.put_env(:mdt_client, MDTClient.Sandbox.Zed, open: fn _address -> :ok end)

    on_exit(fn ->
      Application.delete_env(:mdt_client, Projects)
      Application.delete_env(:mdt_client, MDTClient.Sandbox.Zed)
    end)

    {:ok, _} = MDTClient.Sandbox.add_share(context.username, repo, :ro)
    {:ok, _} = Projects.open(context.username, repo)
    Map.merge(context, %{repo: repo, vm: vm})
  end

  # An agent's handoff: a worktree with one commit, then `mdt handoff`.
  defp hand_off(username, vm, task, title, change) do
    mirror = Path.join(vm, "app")
    {0, _} = Channel.answer("worktree", %{"cwd" => mirror, "name" => task}, username)
    tree = Path.join(mirror <> ".wt", task)
    change.(tree)
    git(tree, ["add", "--all"])
    git(tree, ["commit", "-q", "-m", "work on #{task}"])

    {0, _} =
      Channel.answer(
        "handoff",
        %{
          "cwd" => tree,
          "title" => title,
          "body" => "Done, with tests.",
          "agent" => "claude",
          "thread" => "Fix the login thread"
        },
        username
      )

    [handoff | _] = Sandbox.snapshot(username).handoffs
    handoff
  end

  test "the list shows what agents handed off, open and closed apart", %{
    conn: conn,
    username: username,
    vm: vm
  } do
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/handoffs")
    assert has_element?(view, "#handoffs-empty")

    handoff =
      hand_off(username, vm, "fix", "Fix the login", fn tree ->
        File.write!(Path.join(tree, "a.txt"), "one\ntwo, from the vm\nthree\n")
      end)

    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/handoffs")
    assert has_element?(view, "#handoff-row-#{handoff.id}", "Fix the login")
    assert has_element?(view, "#handoff-row-#{handoff.id}", "fix → master")
    assert has_element?(view, "#handoff-row-#{handoff.id}", "Fix the login thread")
    assert has_element?(view, "#sandbox-nav-handoffs-open", "1")

    {:ok, _} = Handoffs.close(username, handoff.id)
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/handoffs?filter=closed")
    assert has_element?(view, "#handoff-row-#{handoff.id}")
  end

  test "one is read whole and accepted as the agent's commits, or as changes", %{
    conn: conn,
    username: username,
    repo: repo,
    vm: vm
  } do
    handoff =
      hand_off(username, vm, "fix", "Fix the login", fn tree ->
        File.write!(Path.join(tree, "a.txt"), "one\ntwo, from the vm\nthree\n")
        File.write!(Path.join(tree, "mix.exs"), "# the build, changed\n")
      end)

    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/handoffs?id=#{handoff.id}")
    assert has_element?(view, "#handoff-title", "Fix the login")
    assert has_element?(view, "#handoff-thread", "Fix the login thread")
    assert has_element?(view, "#handoff-description", "Done, with tests.")
    assert has_element?(view, "#handoff-merges", "No conflicts with your master")
    assert has_element?(view, "#handoff-hints", "mix.exs, which runs when you build")
    assert has_element?(view, "#handoff-preview", "A fast-forward of master")

    {:ok, files, _html} = live(conn, ~p"/tools/sandbox/handoffs?id=#{handoff.id}&tab=files")
    assert has_element?(files, "#handoff-file-0", "two, from the vm")
    {:ok, commits, _html} = live(conn, ~p"/tools/sandbox/handoffs?id=#{handoff.id}&tab=commits")
    assert has_element?(commits, "#handoff-commits", "work on fix")

    # The changes only, uncommitted; then undone.
    view |> form("#handoff-accept", accept: %{how: "changes"}) |> render_change()
    assert has_element?(view, "#handoff-preview", "Uncommitted changes on master")
    view |> form("#handoff-accept") |> render_submit()
    assert has_element?(view, "#handoff-accepted", "the changes onto master, uncommitted")
    assert git(repo, ["status", "--porcelain"]) == " M a.txt\n M mix.exs\n"
    view |> element("#handoff-undo") |> render_click()
    assert git(repo, ["status", "--porcelain"]) == ""

    # The agent's commits.
    view |> form("#handoff-accept", accept: %{how: "commits"}) |> render_change()
    view |> form("#handoff-accept") |> render_submit()
    assert has_element?(view, "#handoff-state", "Accepted")
    assert git(repo, ["log", "-1", "--format=%s"]) == "work on fix\n"
  end

  test "pending work on your branch stops it; it can be saved as a branch meanwhile", %{
    conn: conn,
    username: username,
    repo: repo,
    vm: vm
  } do
    handoff =
      hand_off(username, vm, "fix", "Fix it", fn tree ->
        File.write!(Path.join(tree, "b.txt"), "new\n")
      end)

    File.write!(Path.join(repo, "a.txt"), "pending\n")
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/handoffs?id=#{handoff.id}")
    assert has_element?(view, "#handoff-preview", "work you haven't committed: a.txt")
    assert has_element?(view, "#handoff-accept-button[disabled]")

    view |> form("#handoff-save-branch", branch: %{name: "look-at-it"}) |> render_submit()
    assert has_element?(view, "#notices", "Saved as look-at-it")
    assert git(repo, ["log", "-1", "--format=%s", "look-at-it"]) == "work on fix\n"
  end

  test "one that conflicts can't be accepted by accident; it goes back to its thread", %{
    conn: conn,
    username: username,
    repo: repo,
    vm: vm
  } do
    handoff =
      hand_off(username, vm, "fix", "Fix it", fn tree ->
        File.write!(Path.join(tree, "a.txt"), "one\ntwo, from the vm\nthree\n")
      end)

    File.write!(Path.join(repo, "a.txt"), "one\ntwo, mine\nthree\n")
    git(repo, ["commit", "-q", "-am", "mine"])

    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/handoffs?id=#{handoff.id}")
    assert has_element?(view, "#handoff-conflicts", "a.txt")
    assert has_element?(view, "#handoff-accept-button[disabled]")

    view
    |> form("#handoff-send-back", send_back: %{note: "Catch up with my branch."})
    |> render_submit()

    assert has_element?(view, "#notices", "Sent back to its thread")
    assert has_element?(view, "#handoff-state", "Sent back")
    assert has_element?(view, "#handoff-timeline", "Catch up with my branch.")
  end

  test "one made to break or mislead the page is shown with all it holds", %{
    conn: conn,
    username: username,
    vm: vm
  } do
    turn = <<0x202E::utf8>>

    handoff =
      hand_off(username, vm, "odd", "Tidy " <> turn <> "eteled", fn tree ->
        File.write!(Path.join(tree, <<"caf", 0xE9, ".txt">>), "a name that isn't UTF-8\n")
        File.write!(Path.join(tree, "safe" <> turn <> "txt.sh"), "echo hi\n")
        File.write!(Path.join(tree, "a.txt"), <<"one\n", 0xFF, 0xFE, " two\e[2J\nthree\n">>)
      end)

    {:ok, view, html} = live(conn, ~p"/tools/sandbox/handoffs?id=#{handoff.id}&tab=files")

    # What the page is sent as: JSON, which takes UTF-8 only.
    assert String.valid?(html)
    assert {:ok, _} = Jason.encode(render(view))
    assert has_element?(view, "#handoff-title", "Tidy \\u{202E}eteled")
    assert has_element?(view, "#handoff-files", "\\u{1B}[2J")
    refute render(view) =~ turn
  end
end
