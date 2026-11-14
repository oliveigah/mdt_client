defmodule MDTClientWeb.SandboxProjectsLiveTest do
  # The folder standing in for the VM, and Zed, are application config, so
  # these tests take turns.
  use MDTClientWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias MDTClient.Sandbox
  alias MDTClient.Sandbox.{Guest, Projects, Zed}
  alias MDTClientWeb.SandboxLive.Projects, as: Page

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

    shared = Path.join(base, "projects")
    repo = Path.join(shared, "app")
    File.mkdir_p!(repo)
    git(repo, ["init", "-q", "-b", "master"])
    File.write!(Path.join(repo, "a.txt"), "one\n")
    git(repo, ["add", "--all"])
    git(repo, ["commit", "-q", "-m", "first"])

    vm = Path.join(base, "vm")
    File.mkdir_p!(vm)
    Application.put_env(:mdt_client, Projects, guest: Guest.local(vm))
    test = self()

    Application.put_env(:mdt_client, Zed,
      open: fn address ->
        send(test, {:zed, address})
        :ok
      end
    )

    on_exit(fn ->
      Application.delete_env(:mdt_client, Projects)
      Application.delete_env(:mdt_client, Zed)
    end)

    Map.merge(context, %{repo: repo, shared: shared, vm: vm})
  end

  test "with no shared folder, the page says where projects come from", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/projects")
    assert has_element?(view, "#projects-no-shares")
  end

  test "every repository in a shared folder is listed; opening one mirrors it and opens Zed", %{
    conn: conn,
    username: username,
    repo: repo,
    shared: shared,
    vm: vm
  } do
    {:ok, _} = Sandbox.add_share(username, shared, :ro)
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/projects")
    row = "#repo-#{Page.key(repo)}"
    assert has_element?(view, "#share-#{Page.key(shared)}", "read-only")
    assert has_element?(view, row, "app")
    assert has_element?(view, "#repo-state-#{Page.key(repo)}", "not opened yet")

    # The VM is stopped in tests, so the button is off; the event is sent as it would be.
    assert has_element?(view, "#repo-zed-#{Page.key(repo)}[disabled]")
    render_click(view, "open_project", %{"path" => repo})

    mirror = Path.join(vm, "app")
    assert_received {:zed, "ssh://mdt-sandbox" <> ^mirror}
    assert has_element?(view, "#notices", "app opened in Zed")
    assert has_element?(view, "#repo-state-#{Page.key(repo)}", "mirror /work/app")
    assert File.read!(Path.join(mirror, "a.txt")) == "one\n"
    assert [%{name: "app"}] = Sandbox.snapshot(username).projects
  end

  test "an opened project's settings are saved, and checked", %{
    conn: conn,
    username: username,
    repo: repo,
    shared: shared
  } do
    {:ok, _} = Sandbox.add_share(username, shared, :ro)
    {:ok, _} = Projects.open(username, repo)
    git(repo, ["branch", "develop"])

    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/projects")
    view |> element("#repo-toggle-#{Page.key(repo)}") |> render_click()
    assert has_element?(view, "#project-settings-form-app", "develop")

    view
    |> form("#project-settings-form-app",
      project: %{targets: ["develop"], default_target: "master"}
    )
    |> render_submit()

    assert has_element?(view, "#project-settings-error-app", "The default must be one of")

    view
    |> form("#project-settings-form-app",
      project: %{targets: ["master", "develop"], default_target: "develop", accept: "changes"}
    )
    |> render_submit()

    assert has_element?(view, "#notices", "Settings of app saved")

    assert [%{targets: ["master", "develop"], default_target: "develop", accept: :changes}] =
             Sandbox.snapshot(username).projects
  end

  test "a read-write shared folder's repositories are listed, and can't be opened", %{
    conn: conn,
    username: username,
    repo: repo,
    shared: shared
  } do
    {:ok, _} = Sandbox.add_share(username, shared, :rw)
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/projects")

    assert has_element?(
             view,
             "#share-writable-#{Page.key(shared)}",
             "The VM can write this folder"
           )

    assert has_element?(view, "#repo-zed-#{Page.key(repo)}[disabled]")

    render_click(view, "open_project", %{"path" => repo})
    assert has_element?(view, "#notices", "which the VM can write")
    refute_received {:zed, _}
    assert Sandbox.snapshot(username).projects == []
  end

  test "a project whose folder is no longer shared is listed apart, and forgotten", %{
    conn: conn,
    username: username,
    repo: repo,
    shared: shared
  } do
    {:ok, _} = Sandbox.add_share(username, shared, :ro)
    {:ok, _} = Projects.open(username, repo)
    :ok = Sandbox.remove_share(username, shared)

    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/projects")
    assert has_element?(view, "#projects-unshared", "app")
    view |> element("#project-forget-app") |> render_click()
    refute has_element?(view, "#projects-unshared")
    assert Sandbox.snapshot(username).projects == []
  end
end
