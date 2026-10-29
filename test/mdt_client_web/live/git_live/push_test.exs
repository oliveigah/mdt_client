defmodule MDTClientWeb.GitLive.PushTest do
  use MDTClientWeb.ConnCase, async: false

  import MDTClient.GitHelpers
  import Phoenix.LiveViewTest

  alias MDTClient.VaultHelpers

  setup %{conn: conn} do
    VaultHelpers.reset_data_dir!()
    on_exit(&VaultHelpers.reset_data_dir!/0)
    %{conn: conn} = sign_in(conn)
    context = initialized_repository(%{})
    {:ok, view, _html} = live(conn, ~p"/tools/git")
    Map.merge(context, %{view: view})
  end

  defp open_and_push(view, path) do
    render_hook(view, "open_repository", %{"path" => path})
    render_async(view)
    view |> element("#git-push") |> render_click()
    render_async(view)
  end

  defp remote_head(base, branch \\ "main"),
    do: git!(Path.join(base, "remote.git"), ["rev-parse", branch])

  test "a first push offers every configured remote, can abort, and sets upstream only when chosen",
       context do
    %{base: base, path: path, view: view, initial_commit: initial} = context
    remote = Path.join(base, "remote.git")
    File.mkdir_p!(remote)
    git!(remote, ["init", "--bare", "--initial-branch=main"])
    git!(path, ["remote", "add", "origin", remote])
    git!(path, ["remote", "add", "backup", remote])
    open_and_push(view, path)

    assert has_element?(view, "#git-confirm-upstream-b3JpZ2lu")
    assert has_element?(view, "#git-confirm-upstream-YmFja3Vw")
    view |> element("#git-confirm-cancel") |> render_click()
    refute has_element?(view, "#git-confirm")
    assert git!(remote, ["for-each-ref"]) == ""
    assert {_, 1} = System.cmd("git", ["-C", path, "config", "--get", "branch.main.remote"])

    view |> element("#git-push") |> render_click()
    view |> element("#git-confirm-upstream-YmFja3Vw") |> render_click()
    render_async(view)
    refute has_element?(view, "#git-confirm")
    assert remote_head(base) == initial
    assert git!(path, ["config", "branch.main.remote"]) == "backup"
  end

  test "an ordinary push succeeds without prompting", context do
    %{base: base, path: path, view: view} = context
    origin!(base, path)
    local = commit_file(path, "local.txt", "local\n", "local")
    open_and_push(view, path)

    refute has_element?(view, "#git-confirm")
    assert remote_head(base) == local
  end

  test "a rejected push can abort, then retry with lease", context do
    %{base: base, path: path, view: view, initial_commit: initial} = context
    origin!(base, path)
    commit_file(path, "published.txt", "published\n", "published")
    git!(path, ["push"])
    git!(path, ["reset", "--hard", initial])
    local = commit_file(path, "revised.txt", "revised\n", "revised")
    before = remote_head(base)
    open_and_push(view, path)

    assert has_element?(view, "#git-confirm-force-with-lease")
    assert has_element?(view, "#git-confirm-force")
    view |> element("#git-confirm-cancel") |> render_click()
    refute has_element?(view, "#git-confirm")
    assert remote_head(base) == before

    view |> element("#git-push") |> render_click()
    render_async(view)
    view |> element("#git-confirm-force-with-lease") |> render_click()
    render_async(view)
    refute has_element?(view, "#git-confirm")
    assert remote_head(base) == local
  end

  test "a stale lease prompts again and only explicit force overwrites unseen remote work",
       context do
    %{base: base, path: path, view: view} = context
    elsewhere = origin!(base, path)
    local = commit_file(path, "local.txt", "local\n", "local")
    first = push_commit!(elsewhere, "main", "first.txt", "first")
    git!(path, ["fetch", "origin"])
    open_and_push(view, path)
    assert has_element?(view, "#git-confirm-force-with-lease")

    latest = push_commit!(elsewhere, "main", "latest.txt", "latest")
    # Even an external fetch while the prompt is open must not weaken the lease.
    git!(path, ["fetch", "origin"])
    view |> element("#git-confirm-force-with-lease") |> render_click()
    render_async(view)
    assert has_element?(view, "#git-confirm-force-with-lease")
    assert has_element?(view, "#git-confirm-title", "The remote branch changed")
    assert remote_head(base) == latest
    refute latest == first

    view |> element("#git-confirm-force") |> render_click()
    render_async(view)
    refute has_element?(view, "#git-confirm")
    assert remote_head(base) == local
  end

  test "retries preserve the upstream option selected on a first push", context do
    %{base: base, path: path, view: view, initial_commit: initial} = context
    origin!(base, path)
    git!(path, ["remote", "add", "backup", Path.join(base, "remote.git")])
    commit_file(path, "published.txt", "published\n", "published")
    git!(path, ["push"])
    git!(path, ["branch", "--unset-upstream"])
    git!(path, ["reset", "--hard", initial])
    local = commit_file(path, "revised.txt", "revised\n", "revised")
    open_and_push(view, path)
    view |> element("#git-confirm-upstream-b3JpZ2lu") |> render_click()
    render_async(view)
    view |> element("#git-confirm-force-with-lease") |> render_click()
    render_async(view)

    refute has_element?(view, "#git-confirm")
    assert git!(path, ["config", "branch.main.remote"]) == "origin"
    assert remote_head(base) == local
  end

  for choice <- ["tracked-upstream", "same-name-upstream"] do
    @choice choice
    test "an upstream name mismatch offers an explicit destination: #{choice}", context do
      %{base: base, path: path, view: view, initial_commit: initial} = context
      origin!(base, path)
      git!(path, ["branch", "-m", "renamed"])
      local = commit_file(path, "local.txt", "local\n", "local")
      open_and_push(view, path)

      assert has_element?(view, "#git-confirm-tracked-upstream")
      assert has_element?(view, "#git-confirm-same-name-upstream")
      view |> element("#git-confirm-#{@choice}") |> render_click()
      render_async(view)
      refute has_element?(view, "#git-confirm")

      if @choice == "tracked-upstream" do
        assert remote_head(base) == local
        assert git!(path, ["config", "branch.renamed.merge"]) == "refs/heads/main"
      else
        assert remote_head(base) == initial
        assert remote_head(base, "renamed") == local
        assert git!(path, ["config", "branch.renamed.merge"]) == "refs/heads/renamed"
      end
    end
  end

  test "a server policy rejection shows an error without force choices", context do
    %{base: base, path: path, view: view, initial_commit: initial} = context
    origin!(base, path)
    commit_file(path, "published.txt", "published\n", "published")
    git!(path, ["push"])
    before = remote_head(base)
    git!(path, ["reset", "--hard", initial])
    commit_file(path, "revised.txt", "revised\n", "revised")
    git!(Path.join(base, "remote.git"), ["config", "receive.denyNonFastForwards", "true"])
    open_and_push(view, path)
    view |> element("#git-confirm-force") |> render_click()
    render_async(view)

    refute has_element?(view, "#git-confirm")
    assert has_element?(view, "#notices [role=alert]")
    assert remote_head(base) == before
  end

  test "a transport failure shows an error without force choices", context do
    %{base: base, path: path, view: view} = context
    origin!(base, path)
    git!(path, ["remote", "set-url", "origin", Path.join(base, "missing.git")])
    open_and_push(view, path)

    refute has_element?(view, "#git-confirm")
    assert has_element?(view, "#notices [role=alert]")
  end
end
