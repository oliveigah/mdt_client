defmodule MDTClientWeb.SandboxProjectsLiveTest do
  # The folder standing in for the VM, and Zed, are application config, so
  # these tests take turns.
  use MDTClientWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias MDTClient.Sandbox
  alias MDTClient.Sandbox.{Guest, Projects, Zed}

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

    Map.merge(context, %{repo: repo, vm: vm})
  end

  test "opening a repository makes it a project, mirrors it, and opens it in Zed", %{
    conn: conn,
    username: username,
    repo: repo,
    vm: vm
  } do
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/projects")
    assert has_element?(view, "#projects-empty")

    view |> form("#project-form", project: %{path: Path.join(repo, "nope")}) |> render_submit()
    assert has_element?(view, "#project-error", "is not a folder in a git repository")

    view |> form("#project-form", project: %{path: repo}) |> render_submit()
    mirror = Path.join(vm, "app")
    assert_received {:zed, "ssh://mdt-sandbox" <> ^mirror}
    assert has_element?(view, "#notices", "app opened in Zed")
    assert has_element?(view, "#project-app", repo)
    assert has_element?(view, "#project-targets-app", "master")
    assert File.read!(Path.join(mirror, "a.txt")) == "one\n"

    # The button is off while the VM is stopped, as it is in tests.
    assert has_element?(view, "#project-zed-app[disabled]")
    render_click(view, "open_project", %{"name" => "app", "folder" => mirror <> ".wt/fix"})
    assert_received {:zed, "ssh://mdt-sandbox" <> folder}
    assert folder == mirror <> ".wt/fix"

    assert [%{name: "app"}] = Sandbox.snapshot(username).projects
  end

  test "its settings are saved, and checked", %{conn: conn, username: username, repo: repo} do
    {:ok, _} = Projects.add(username, repo)
    git(repo, ["branch", "develop"])

    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/projects")
    view |> element("#project-settings-app") |> render_click()
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
    assert has_element?(view, "#project-targets-app", "develop")
    assert has_element?(view, "#project-targets-app", "accepted as changes")

    assert [%{targets: ["master", "develop"], default_target: "develop", accept: :changes}] =
             Sandbox.snapshot(username).projects

    view |> element("#project-remove-app") |> render_click()
    assert has_element?(view, "#projects-empty")
  end
end
