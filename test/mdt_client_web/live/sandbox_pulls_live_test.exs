defmodule MDTClientWeb.SandboxPullsLiveTest do
  # The folder standing in for the VM is application config, so these tests
  # take turns.
  use MDTClientWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias MDTClient.Sandbox
  alias MDTClient.Sandbox.{Channel, Guest, PullRequests}

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
    base = Path.join(System.tmp_dir!(), "pulls-live-#{System.unique_integer([:positive])}")
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
    Application.put_env(:mdt_client, PullRequests, guest: Guest.local(vm))
    on_exit(fn -> Application.delete_env(:mdt_client, PullRequests) end)

    Map.merge(context, %{repo: repo, vm: vm})
  end

  # An agent's pull request: a clone of your repository with one commit on
  # a branch of its own, then `mdt pr`.
  defp open(username, vm, repo, branch, title, change) do
    clone = Path.join(vm, branch)
    {_, 0} = System.cmd("git", ["clone", "-q", repo, clone], env: Guest.git_env())
    git(clone, ["checkout", "-q", "-b", branch])
    change.(clone)
    git(clone, ["add", "--all"])
    git(clone, ["commit", "-q", "-m", "work on #{branch}"])

    {0, _} =
      Channel.answer(
        "pr",
        %{"cwd" => clone, "title" => title, "body" => "Done, with tests.", "agent" => "claude"},
        username
      )

    [pull | _] = Sandbox.snapshot(username).pulls
    pull
  end

  test "the list shows what agents opened, open and closed apart", %{
    conn: conn,
    username: username,
    repo: repo,
    vm: vm
  } do
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/pulls")
    assert has_element?(view, "#pulls-empty")

    pull =
      open(username, vm, repo, "fix", "Fix the login", fn clone ->
        File.write!(Path.join(clone, "a.txt"), "one\ntwo, from the vm\nthree\n")
      end)

    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/pulls")
    assert has_element?(view, "#pull-row-#{pull.id}", "Fix the login")
    assert has_element?(view, "#pull-row-#{pull.id}", "fix → master")
    assert has_element?(view, "#sandbox-nav-pulls-open", "1")

    {:ok, _} = PullRequests.close(username, pull.id)
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/pulls")
    refute has_element?(view, "#pull-row-#{pull.id}")
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/pulls?filter=closed")
    assert has_element?(view, "#pull-row-#{pull.id}", "Fix the login")
  end

  test "one is read as a conversation, its commits and its files, and brought in uncommitted",
       %{conn: conn, username: username, repo: repo, vm: vm} do
    pull =
      open(username, vm, repo, "fix", "Fix the login", fn clone ->
        File.write!(Path.join(clone, "a.txt"), "one\ntwo, from the vm\nthree\n")
        File.write!(Path.join(clone, "mix.exs"), "# the build, changed\n")
      end)

    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/pulls?pr=#{pull.id}")
    assert has_element?(view, "#pull-title", "Fix the login")
    assert has_element?(view, "#pull-state", "Open")
    assert has_element?(view, "#pull-description", "Done, with tests.")
    assert has_element?(view, "#pull-merges", "No conflicts with your master")
    assert has_element?(view, "#pull-hints", "mix.exs, which runs when you build")
    assert has_element?(view, "#pull-where-wt-0", repo)
    assert has_element?(view, "#pull-preview", "Lands cleanly")

    {:ok, commits, _html} = live(conn, ~p"/tools/sandbox/pulls?pr=#{pull.id}&tab=commits")
    assert has_element?(commits, "#pull-commits", "work on fix")

    {:ok, files, _html} = live(conn, ~p"/tools/sandbox/pulls?pr=#{pull.id}&tab=files")
    assert has_element?(files, "#pull-file-0", "a.txt")
    assert has_element?(files, "#pull-file-0", "two, from the vm")

    head = git(repo, ["rev-parse", "HEAD"])
    view |> form("#pull-bring") |> render_submit()
    assert has_element?(view, "#notices", "Brought in")
    assert has_element?(view, "#pull-state", "Brought in")
    assert has_element?(view, "#pull-landed", "the changes, uncommitted, into master")
    assert git(repo, ["status", "--porcelain"]) == " M a.txt\n M mix.exs\n"
    assert git(repo, ["rev-parse", "HEAD"]) == head

    view |> element("#pull-undo") |> render_click()
    assert has_element?(view, "#pull-state", "Open")
    assert git(repo, ["status", "--porcelain"]) == ""
  end

  test "choosing the agent's commits on a new branch shows what that does, and does it", %{
    conn: conn,
    username: username,
    repo: repo,
    vm: vm
  } do
    pull =
      open(username, vm, repo, "fix", "Fix it", fn clone ->
        File.write!(Path.join(clone, "b.txt"), "new\n")
      end)

    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/pulls?pr=#{pull.id}")
    refute has_element?(view, "#pull-where-new-branch")

    # A branch checked out nowhere is a place for commits only.
    view |> form("#pull-bring", land: %{how: "commits"}) |> render_change()
    assert has_element?(view, "#pull-where-new-branch")
    view |> form("#pull-bring", land: %{how: "commits", where: "new_branch"}) |> render_change()
    assert has_element?(view, "#pull-new-branch[value=fix]")

    view
    |> form("#pull-bring", land: %{how: "commits", where: "new_branch", branch: "master"})
    |> render_change()

    assert has_element?(view, "#pull-preview", "You already have a branch master.")
    assert has_element?(view, "#pull-bring-button[disabled]")

    view
    |> form("#pull-bring", land: %{how: "commits", where: "new_branch", branch: "from-the-vm"})
    |> render_change()

    view |> form("#pull-bring") |> render_submit()
    assert has_element?(view, "#pull-landed", "the agent's commits as the new branch from-the-vm")
    assert git(repo, ["log", "-1", "--format=%s", "from-the-vm"]) == "work on fix\n"
  end

  test "one that conflicts can't be brought in by accident; it goes back with a note and your branch",
       %{conn: conn, username: username, repo: repo, vm: vm} do
    pull =
      open(username, vm, repo, "fix", "Fix it", fn clone ->
        File.write!(Path.join(clone, "a.txt"), "one\ntwo, from the vm\nthree\n")
      end)

    File.write!(Path.join(repo, "a.txt"), "one\ntwo, mine\nthree\n")
    git(repo, ["commit", "-q", "-am", "mine"])

    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/pulls?pr=#{pull.id}")
    assert has_element?(view, "#pull-conflicts", "a.txt")
    assert has_element?(view, "#pull-preview", "Conflicts there")
    assert has_element?(view, "#pull-bring-button[disabled]")
    assert has_element?(view, "#pull-bring-anyway[data-confirm]")
    assert has_element?(view, "#pull-send-base[checked]")

    view
    |> form("#pull-send-back", send_back: %{note: "Bring it up to date with my branch."})
    |> render_submit()

    assert has_element?(view, "#notices", "Sent back to the agent")
    assert has_element?(view, "#pull-state", "Sent back")
    assert has_element?(view, "#pull-timeline", "Bring it up to date with my branch.")
    assert has_element?(view, "#pull-timeline", "as host/master")

    assert git(Path.join(vm, "fix"), ["rev-parse", "host/master"]) ==
             git(repo, ["rev-parse", "master"])

    assert File.read!(Path.join(repo, "a.txt")) == "one\ntwo, mine\nthree\n"
  end

  test "one made to break or mislead the page is shown with all it holds", %{
    conn: conn,
    username: username,
    repo: repo,
    vm: vm
  } do
    turn = <<0x202E::utf8>>

    pull =
      open(username, vm, repo, "odd", "Tidy " <> turn <> "eteled", fn clone ->
        File.write!(Path.join(clone, <<"caf", 0xE9, ".txt">>), "a name that isn't UTF-8\n")
        File.write!(Path.join(clone, "safe" <> turn <> "txt.sh"), "echo hi\n")
        File.write!(Path.join(clone, "a.txt"), <<"one\n", 0xFF, 0xFE, " two\e[2J\nthree\n">>)
      end)

    {:ok, view, html} = live(conn, ~p"/tools/sandbox/pulls?pr=#{pull.id}&tab=files")

    # What the page is sent as: JSON, which takes UTF-8 only.
    assert String.valid?(html)
    assert {:ok, _} = Jason.encode(render(view))
    assert has_element?(view, "#pull-title", "Tidy \\u{202E}eteled")
    assert has_element?(view, "#pull-files", "\\u{1B}[2J")
    refute render(view) =~ turn
  end
end
