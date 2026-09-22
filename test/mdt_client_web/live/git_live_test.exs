defmodule MDTClientWeb.GitLiveTest do
  use MDTClientWeb.ConnCase

  import MDTClient.GitHelpers
  import Phoenix.LiveViewTest

  alias MDTClient.Preferences
  alias MDTClient.VaultHelpers
  alias MDTClientWeb.GitLive.Components

  setup %{conn: conn} do
    VaultHelpers.reset_data_dir!()
    on_exit(&VaultHelpers.reset_data_dir!/0)
    %{conn: conn} = sign_in(conn)

    context = initialized_repository(%{})
    {:ok, view, _html} = live(conn, ~p"/tools/git")

    Map.merge(context, %{conn: conn, view: view})
  end

  defp open(view, path) do
    render_hook(view, "open_repository", %{"path" => path})
    render_async(view)
    view
  end

  defp count(view, selector) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> Enum.count()
  end

  defp head_commit(path), do: git!(path, ["rev-parse", "HEAD"])

  ## Empty state and folder selection

  test "starts on an empty state with a folder picker", %{view: view} do
    assert has_element?(view, "#git-empty-state")
    assert has_element?(view, "#git-open-folder")
    assert has_element?(view, "#git-empty-open")
    refute has_element?(view, "#git-branches")
    refute has_element?(view, "#git-graph")
  end

  test "falls back to a typed path when the native picker cannot run", %{view: view} do
    refute has_element?(view, "#git-open-dialog")

    render_hook(view, "folder_dialog_unavailable", %{
      "reason" => "The native folder picker is only available in the desktop app."
    })

    assert has_element?(view, "#git-open-dialog")
    assert has_element?(view, "#git-manual-open")
    assert render(view) =~ "only available in the desktop app"

    view |> element("#git-close-open-dialog") |> render_click()
    refute has_element?(view, "#git-open-dialog")
  end

  test "the fallback is reachable while a repository is already open", context do
    %{view: view, path: path} = context
    open(view, path)

    refute has_element?(view, "#git-open-dialog")

    render_hook(view, "folder_dialog_unavailable", %{"reason" => "no picker here"})

    assert has_element?(view, "#git-open-dialog")
    assert has_element?(view, "#git-manual-open")
  end

  test "a bad path typed in the fallback keeps the dialog open with the error", context do
    %{view: view, path: path, base: base} = context
    open(view, path)
    render_hook(view, "folder_dialog_unavailable", %{"reason" => "no picker here"})

    view |> form("#git-manual-open", %{"path" => Path.join(base, "nope")}) |> render_submit()
    render_async(view)

    assert has_element?(view, "#git-open-dialog")
    assert has_element?(view, "#git-open-dialog-error")
    assert count(view, "#git-tabs [role=tab]") == 1
  end

  test "the fallback opens a repository and closes itself", context do
    %{view: view, path: path} = context
    render_hook(view, "folder_dialog_unavailable", %{"reason" => "no picker here"})

    view |> form("#git-manual-open", %{"path" => path}) |> render_submit()
    render_async(view)

    refute has_element?(view, "#git-open-dialog")
    assert count(view, "#git-tabs [role=tab]") == 1
  end

  test "shows the typed backend error for a folder that is not a worktree", context do
    %{view: view, base: base} = context
    outside = Path.join(base, "not-a-repo")
    File.mkdir_p!(outside)

    open(view, outside)

    assert has_element?(view, "#git-open-error")
    assert view |> element("#git-open-error") |> render() =~ "Not a Git worktree"
    assert view |> element("#git-open-error") |> render() =~ "not a git repository"
    assert has_element?(view, "#git-empty-state")
  end

  ## Tabs

  test "opening a folder creates a tab with the three panels", context do
    %{view: view, path: path} = context

    open(view, path)

    assert has_element?(view, "#git-tabs [role=tab]")
    assert render(view) =~ Path.basename(path)
    assert has_element?(view, "#git-branches")
    assert has_element?(view, "#git-graph")
    assert has_element?(view, "#git-inspector")
    assert has_element?(view, "#git-branches-resizer")
    assert has_element?(view, "#git-inspector-resizer")
    refute has_element?(view, "#git-empty-state")
  end

  test "opening a nested folder opens the worktree root once", context do
    %{view: view, path: path} = context
    nested = Path.join(path, "deeply/nested")
    File.mkdir_p!(nested)

    open(view, nested)
    assert count(view, "#git-tabs [role=tab]") == 1

    open(view, path)
    assert count(view, "#git-tabs [role=tab]") == 1
  end

  test "opens, switches between and closes repository tabs", context do
    %{view: view, base: base, path: path} = context

    other = Path.join(base, "other")
    File.mkdir_p!(other)
    git!(other, ["init", "--initial-branch=main"])
    git!(other, ["config", "user.name", "MDT Test"])
    git!(other, ["config", "user.email", "mdt@example.test"])
    commit_file(other, "other.txt", "other\n", "other commit")

    open(view, path)
    open(view, other)

    assert count(view, "#git-tabs [role=tab]") == 2
    assert render(view) =~ "other commit"

    [first, _second] = tab_ids(view)
    view |> element("#git-tab-#{first}") |> render_click()

    assert render(view) =~ "initial commit"
    assert has_element?(view, "#git-tab-#{first}[aria-selected=true]")

    view |> element("#git-close-tab-#{first}") |> render_click()
    assert count(view, "#git-tabs [role=tab]") == 1
    assert render(view) =~ "other commit"

    [last] = tab_ids(view)
    view |> element("#git-close-tab-#{last}") |> render_click()
    assert has_element?(view, "#git-empty-state")
  end

  defp tab_ids(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#git-tabs [role=tab]")
    |> LazyHTML.attribute("id")
    |> Enum.map(&String.replace_prefix(&1, "git-tab-", ""))
  end

  ## Branches

  test "lists local and remote branches with the current one marked", context do
    %{view: view, path: path, base: base} = context

    git!(path, ["branch", "feature"])
    remote = Path.join(base, "remote.git")
    File.mkdir_p!(remote)
    git!(remote, ["init", "--bare"])
    git!(path, ["remote", "add", "origin", remote])
    git!(path, ["push", "-u", "origin", "main"])

    open(view, path)

    assert has_element?(view, "#git-local-branches")
    assert has_element?(view, "#git-remote-branches")
    assert has_element?(view, "#git-branch-#{slug("refs/heads/feature")}")
    assert has_element?(view, "#git-branch-#{slug("refs/remotes/origin/main")}")
    assert render(view) =~ "origin/main"
  end

  test "filters the branch list", context do
    %{view: view, path: path} = context
    git!(path, ["branch", "feature-one"])
    git!(path, ["branch", "other"])

    open(view, path)

    view
    |> element("#git-branch-search")
    |> render_change(%{"filter" => "feature"})

    assert has_element?(view, "#git-branch-#{slug("refs/heads/feature-one")}")
    refute has_element?(view, "#git-branch-#{slug("refs/heads/other")}")

    view |> element("#git-branch-search") |> render_change(%{"filter" => "nothing"})
    assert has_element?(view, "#git-branches-empty")
  end

  test "selecting a branch marks it and opens its actions", context do
    %{view: view, path: path} = context
    git!(path, ["branch", "feature"])
    open(view, path)

    feature = slug("refs/heads/feature")

    view |> element("#git-select-branch-#{feature}") |> render_click()
    assert has_element?(view, "#git-select-branch-#{feature}[aria-selected=true]")

    view |> element("#git-branch-menu-button-#{feature}") |> render_click()
    assert has_element?(view, "#git-branch-menu-#{feature}[role=menu]")
    assert has_element?(view, "#git-menu-checkout-#{feature}")

    view |> element("#git-menu-checkout-#{feature}") |> render_click()
    render_async(view)

    assert git!(path, ["rev-parse", "--abbrev-ref", "HEAD"]) == "feature"
    assert render(view) =~ "feature"
    refute has_element?(view, "#git-branch-menu-#{feature}")
  end

  test "checking out the current branch is disabled", context do
    %{view: view, path: path} = context
    open(view, path)

    main = slug("refs/heads/main")
    view |> element("#git-branch-menu-button-#{main}") |> render_click()

    assert has_element?(view, "#git-menu-checkout-#{main}[disabled]")
    assert has_element?(view, "#git-menu-merge-#{main}[disabled]")
  end

  test "creating a branch refreshes the snapshot", context do
    %{view: view, path: path} = context
    open(view, path)

    view |> element("#git-create-branch") |> render_click()
    assert has_element?(view, "#git-action-form")

    view
    |> form("#git-action-form", %{"value" => "from-ui", "checkout" => "true"})
    |> render_submit()

    render_async(view)

    assert git!(path, ["rev-parse", "--abbrev-ref", "HEAD"]) == "from-ui"
    assert has_element?(view, "#git-branch-#{slug("refs/heads/from-ui")}")
    refute has_element?(view, "#git-action-form")
  end

  test "deleting a branch asks first", context do
    %{view: view, path: path} = context
    git!(path, ["branch", "doomed"])
    open(view, path)

    doomed = slug("refs/heads/doomed")
    view |> element("#git-branch-menu-button-#{doomed}") |> render_click()
    view |> element("#git-menu-delete-#{doomed}") |> render_click()

    assert has_element?(view, "#git-confirm")
    assert render(view) =~ "doomed"

    view |> element("#git-confirm-cancel") |> render_click()
    refute has_element?(view, "#git-confirm")
    assert git!(path, ["branch", "--list", "doomed"]) =~ "doomed"

    view |> element("#git-branch-menu-button-#{doomed}") |> render_click()
    view |> element("#git-menu-delete-#{doomed}") |> render_click()
    view |> element("#git-confirm-accept") |> render_click()
    render_async(view)

    assert git!(path, ["branch", "--list", "doomed"]) == ""
    refute has_element?(view, "#git-branch-#{doomed}")
  end

  test "renaming a branch through the action form", context do
    %{view: view, path: path} = context
    git!(path, ["branch", "old-name"])
    open(view, path)

    old = slug("refs/heads/old-name")
    view |> element("#git-branch-menu-button-#{old}") |> render_click()
    view |> element("#git-menu-rename-#{old}") |> render_click()

    assert has_element?(view, "#git-action-form")

    view |> form("#git-action-form", %{"value" => "new-name"}) |> render_submit()
    render_async(view)

    assert git!(path, ["branch", "--list", "new-name"]) =~ "new-name"
    assert has_element?(view, "#git-branch-#{slug("refs/heads/new-name")}")
    refute has_element?(view, "#git-branch-#{old}")
  end

  test "checking out a remote branch as a local tracking branch", context do
    %{view: view, path: path, base: base} = context

    remote = Path.join(base, "remote.git")
    File.mkdir_p!(remote)
    git!(remote, ["init", "--bare"])
    git!(path, ["remote", "add", "origin", remote])
    git!(path, ["push", "origin", "main"])
    git!(path, ["push", "origin", "main:refs/heads/shipped"])
    git!(path, ["fetch", "origin"])

    open(view, path)

    shipped = slug("refs/remotes/origin/shipped")
    view |> element("#git-branch-menu-button-#{shipped}") |> render_click()
    view |> element("#git-menu-checkout-remote-#{shipped}") |> render_click()

    assert has_element?(view, "#git-action-form")

    view |> form("#git-action-form", %{"value" => "shipped"}) |> render_submit()
    render_async(view)

    assert git!(path, ["rev-parse", "--abbrev-ref", "HEAD"]) == "shipped"
    assert git!(path, ["rev-parse", "--abbrev-ref", "shipped@{upstream}"]) == "origin/shipped"
    assert has_element?(view, "#git-branch-#{slug("refs/heads/shipped")}")
  end

  ## Commits

  test "renders the graph and selects the head commit", context do
    %{view: view, path: path} = context
    commit_file(path, "second.txt", "second\n", "second commit")
    open(view, path)

    head = head_commit(path)

    assert count(view, "#git-commits [role=option]") == 2
    assert has_element?(view, "#git-commit-#{head}")
    assert has_element?(view, "#git-select-commit-#{head}[aria-selected=true]")
    assert has_element?(view, "#git-commit-details")
    assert render(view) =~ "second commit"
  end

  test "selecting a commit updates the inspector", context do
    %{view: view, path: path, initial_commit: initial} = context
    commit_file(path, "second.txt", "second\n", "second commit")
    open(view, path)

    view |> element("#git-select-commit-#{initial}") |> render_click()

    details = view |> element("#git-commit-details") |> render()
    assert details =~ "initial commit"
    assert details =~ initial
    assert details =~ "MDT Test"
    assert details =~ "mdt@example.test"
    assert details =~ "Not signed"
    assert details =~ "A root commit"
  end

  test "a commit inspector links to its parents", context do
    %{view: view, path: path, initial_commit: initial} = context
    commit_file(path, "second.txt", "second\n", "second commit")
    open(view, path)

    head = head_commit(path)

    view |> element("#git-parent-#{head}-#{initial}") |> render_click()

    assert has_element?(view, "#git-select-commit-#{initial}[aria-selected=true]")
    assert view |> element("#git-commit-details") |> render() =~ "initial commit"
  end

  test "the commit menu can check out a commit detached", context do
    %{view: view, path: path, initial_commit: initial} = context
    commit_file(path, "second.txt", "second\n", "second commit")
    open(view, path)

    view |> element("#git-commit-menu-button-#{initial}") |> render_click()
    assert has_element?(view, "#git-commit-menu-#{initial}[role=menu]")

    view |> element("#git-menu-detach-#{initial}") |> render_click()
    render_async(view)

    assert git!(path, ["rev-parse", "HEAD"]) == initial
    assert render(view) =~ "detached at"
  end

  test "a hard reset is confirmed before it runs", context do
    %{view: view, path: path, initial_commit: initial} = context
    commit_file(path, "second.txt", "second\n", "second commit")
    open(view, path)

    view |> element("#git-commit-menu-button-#{initial}") |> render_click()
    view |> element("#git-menu-hard-reset-#{initial}") |> render_click()

    assert has_element?(view, "#git-confirm")
    assert render(view) =~ "Hard reset"
    assert git!(path, ["rev-parse", "HEAD"]) != initial

    view |> element("#git-confirm-accept") |> render_click()
    render_async(view)

    assert git!(path, ["rev-parse", "HEAD"]) == initial
    assert count(view, "#git-commits [role=option]") == 1
  end

  test "the commit limit can be raised", context do
    %{view: view, path: path} = context
    open(view, path)

    assert has_element?(view, "#git-graph-limit option[value='5000']")

    view
    |> element("form[phx-change=set_limit]")
    |> render_change(%{"limit" => "5000"})

    render_async(view)

    assert has_element?(view, "#git-graph-limit option[value='5000'][selected]")
  end

  test "editing a commit message rewrites it", context do
    %{view: view, path: path} = context
    open(view, path)

    head = head_commit(path)

    view |> element("#git-commit-menu-button-#{head}") |> render_click()
    view |> element("#git-menu-edit-message-#{head}") |> render_click()

    assert has_element?(view, "#git-action-form")
    assert view |> element("#git-action-form") |> render() =~ "initial commit"

    view |> form("#git-action-form", %{"value" => "a better message"}) |> render_submit()
    render_async(view)

    assert git!(path, ["log", "-1", "--format=%s"]) == "a better message"
    assert render(view) =~ "a better message"
  end

  test "the graph draws one lane per concurrent branch", context do
    %{view: view, path: path} = context

    git!(path, ["checkout", "-b", "side"])
    commit_file(path, "side.txt", "side\n", "side work")
    git!(path, ["checkout", "main"])
    commit_file(path, "main.txt", "main\n", "main work")
    git!(path, ["merge", "--no-ff", "-m", "merge side", "side"])

    open(view, path)

    merge = head_commit(path)

    assert count(view, "#git-commits [role=option]") == 4
    # The merge row draws its own node plus the two edges leaving it.
    assert count(view, "#git-commit-#{merge} svg path") == 2
    assert count(view, "#git-commit-#{merge} svg circle") == 1
    assert view |> element("#git-commit-#{merge}") |> render() =~ "main"
  end

  test "right clicking a commit opens its menu at the pointer", context do
    %{view: view, path: path} = context
    open(view, path)

    head = head_commit(path)

    # The row carries the data the list hook reads on contextmenu.
    assert has_element?(view, "#git-commit-#{head}[data-menu-kind=commit]")

    render_hook(view, "open_menu", %{"kind" => "commit", "id" => head, "x" => 412, "y" => 260})

    assert has_element?(view, "#git-commit-menu-#{head}[role=menu]")
    assert has_element?(view, "#git-commit-menu-#{head}[data-x='412'][data-y='260']")
    assert has_element?(view, "#git-menu-detach-#{head}")
    assert has_element?(view, "#git-menu-branch-here-#{head}")
    assert has_element?(view, "#git-menu-copy-sha-#{head}")
  end

  test "the menu is rendered outside the scrolling panels and over no backdrop", context do
    %{view: view, path: path} = context
    open(view, path)

    head = head_commit(path)
    view |> element("#git-commit-menu-button-#{head}") |> render_click()

    assert has_element?(view, "#git-commit-menu-#{head}")
    assert count(view, "#git-commits #git-commit-menu-#{head}") == 0
    assert count(view, "#git-branches #git-commit-menu-#{head}") == 0

    # A backdrop over the rows would eat the next right click, and the webview
    # would answer it with its own menu instead.
    assert count(view, "#git-menu-backdrop") == 0

    # Clicking the same trigger again closes it.
    view |> element("#git-commit-menu-button-#{head}") |> render_click()
    refute has_element?(view, "#git-commit-menu-#{head}")
  end

  test "the selected commit keeps a visible action button", context do
    %{view: view, path: path, initial_commit: initial} = context
    commit_file(path, "second.txt", "second\n", "second commit")
    open(view, path)

    head = head_commit(path)

    # Selected rows keep the trigger on screen; the rest reveal it on hover.
    assert view |> element("#git-commit-menu-button-#{head}") |> render() =~ "opacity-100"
    assert view |> element("#git-commit-menu-button-#{initial}") |> render() =~ "opacity-0"

    view |> element("#git-select-commit-#{initial}") |> render_click()

    assert view |> element("#git-commit-menu-button-#{initial}") |> render() =~ "opacity-100"
  end

  test "the inspector opens the same menu for the selected commit", context do
    %{view: view, path: path} = context
    open(view, path)

    head = head_commit(path)
    view |> element("#git-commit-actions") |> render_click()

    assert has_element?(view, "#git-commit-menu-#{head}[data-anchor=git-commit-actions]")

    view |> element("#git-menu-branch-here-#{head}") |> render_click()
    assert has_element?(view, "#git-action-form")
  end

  test "escape closes an open menu", context do
    %{view: view, path: path} = context
    open(view, path)

    head = head_commit(path)
    view |> element("#git-commit-menu-button-#{head}") |> render_click()
    assert has_element?(view, "#git-commit-menu-#{head}")

    render_keydown(view, "close_overlays", %{"key" => "Escape"})
    refute has_element?(view, "#git-commit-menu-#{head}")
  end

  test "the graph labels local and remote branches differently", context do
    %{view: view, path: path, base: base} = context

    remote = Path.join(base, "remote.git")
    File.mkdir_p!(remote)
    git!(remote, ["init", "--bare"])
    git!(path, ["remote", "add", "origin", remote])
    git!(path, ["push", "-u", "origin", "main"])

    open(view, path)

    row = view |> element("#git-commit-#{head_commit(path)}") |> render()

    assert row =~ "Current branch main"
    assert row =~ "Remote branch origin/main"
    assert row =~ "hero-check-circle-micro"
    assert row =~ "hero-cloud-micro"
    assert has_element?(view, "#git-commit-columns")
  end

  test "the current branch keeps its chip when a commit carries many refs", context do
    %{view: view, path: path} = context
    for name <- ~w(alpha beta gamma delta), do: git!(path, ["branch", name])

    open(view, path)

    row = view |> element("#git-commit-#{head_commit(path)}") |> render()

    # Two chips plus a counter, and the branch HEAD is on is never the one hidden.
    assert row =~ "Current branch main"
    assert row =~ "+3"
  end

  ## Errors and conflicts

  test "a failed command shows the typed error", context do
    %{view: view, path: path} = context
    open(view, path)

    render_hook(view, "request", %{"action" => "merge", "revision" => "does-not-exist"})
    render_async(view)

    assert has_element?(view, "#git-error")
    assert render(view) =~ "Git reported a problem"
  end

  test "a conflict moves the inspector into resolution mode", context do
    %{view: view, path: path} = context

    git!(path, ["checkout", "-b", "side"])
    commit_file(path, "conflict.txt", "side\n", "side change")
    git!(path, ["checkout", "main"])
    commit_file(path, "conflict.txt", "main\n", "main change")

    open(view, path)

    render_hook(view, "request", %{"action" => "merge", "revision" => "side"})
    render_async(view)

    assert has_element?(view, "#git-operation")
    assert has_element?(view, "#git-operation-continue")
    assert has_element?(view, "#git-operation-abort")
    assert has_element?(view, "#git-operation-skip[disabled]")
    assert render(view) =~ "Merge in progress"
    assert has_element?(view, "#git-working-tree")
    assert render(view) =~ "conflict.txt"

    view |> element("#git-operation-abort") |> render_click()
    assert has_element?(view, "#git-confirm")
    view |> element("#git-confirm-accept") |> render_click()
    render_async(view)

    refute has_element?(view, "#git-operation")
  end

  ## Working tree

  test "lists staged and unstaged changes with empty states", context do
    %{view: view, path: path} = context
    open(view, path)

    view |> element("#git-panel-changes") |> render_click()
    assert has_element?(view, "#git-changes-empty")
    assert has_element?(view, "#git-stashes-empty")

    File.write!(Path.join(path, "README.md"), "changed\n")
    File.write!(Path.join(path, "new.txt"), "new\n")
    git!(path, ["add", "--", "new.txt"])

    view |> element("#git-refresh") |> render_click()
    render_async(view)

    assert has_element?(view, "#git-staged")
    assert has_element?(view, "#git-unstaged")
    assert has_element?(view, "#git-file-staged-#{slug("new.txt")}")
    assert has_element?(view, "#git-file-unstaged-#{slug("README.md")}")
  end

  test "stages and unstages only the selected paths", context do
    %{view: view, path: path} = context

    File.write!(Path.join(path, "one.txt"), "one\n")
    File.write!(Path.join(path, "two.txt"), "two\n")
    open(view, path)

    view |> element("#git-panel-changes") |> render_click()
    view |> element("#git-file-unstaged-#{slug("one.txt")}") |> render_click()

    assert has_element?(view, "#git-file-unstaged-#{slug("one.txt")}[aria-selected=true]")

    view |> element("#git-stage-selected") |> render_click()
    render_async(view)

    assert git!(path, ["diff", "--cached", "--name-only"]) == "one.txt"
    assert has_element?(view, "#git-file-staged-#{slug("one.txt")}")
    refute has_element?(view, "#git-file-staged-#{slug("two.txt")}")

    # The refresh keeps the path selected, so it can be sent straight back.
    assert has_element?(view, "#git-file-staged-#{slug("one.txt")}[aria-selected=true]")
    view |> element("#git-unstage-selected") |> render_click()
    render_async(view)

    assert git!(path, ["diff", "--cached", "--name-only"]) == ""
  end

  test "stage is disabled until something is selected", context do
    %{view: view, path: path} = context
    File.write!(Path.join(path, "one.txt"), "one\n")
    open(view, path)

    view |> element("#git-panel-changes") |> render_click()
    assert has_element?(view, "#git-stage-selected[disabled]")

    view |> element("#git-select-all-paths") |> render_click()
    refute has_element?(view, "#git-stage-selected[disabled]")

    view |> element("#git-clear-paths") |> render_click()
    assert has_element?(view, "#git-stage-selected[disabled]")
  end

  test "stashes only the selected paths and lists the stash", context do
    %{view: view, path: path} = context

    File.write!(Path.join(path, "README.md"), "changed\n")
    File.write!(Path.join(path, "untouched.txt"), "untouched\n")
    open(view, path)

    view |> element("#git-panel-changes") |> render_click()
    view |> element("#git-file-unstaged-#{slug("README.md")}") |> render_click()

    view
    |> form("#git-stash-form", %{"message" => "just the readme", "include_untracked" => "true"})
    |> render_submit()

    render_async(view)

    assert git!(path, ["status", "--porcelain", "--", "README.md"]) == ""
    assert File.exists?(Path.join(path, "untouched.txt"))
    assert has_element?(view, "#git-stash-0")
    assert render(view) =~ "just the readme"
    assert render(view) =~ "complete stash"
    # The spent draft does not linger in the form.
    assert view |> element("#git-stash-message") |> render() =~ ~s(value="")

    view |> element("#git-stash-pop-0") |> render_click()
    render_async(view)

    assert File.read!(Path.join(path, "README.md")) == "changed\n"
    assert has_element?(view, "#git-stashes-empty")
  end

  test "committing the staged files refreshes the graph", context do
    %{view: view, path: path} = context

    File.write!(Path.join(path, "committed.txt"), "committed\n")
    open(view, path)

    view |> element("#git-panel-changes") |> render_click()
    view |> element("#git-select-all-paths") |> render_click()
    view |> element("#git-stage-selected") |> render_click()
    render_async(view)

    view |> form("#git-commit-form", %{"message" => "from the inspector"}) |> render_submit()
    render_async(view)

    assert git!(path, ["log", "-1", "--format=%s"]) == "from the inspector"
    assert render(view) =~ "from the inspector"
    assert count(view, "#git-commits [role=option]") == 2
  end

  ## SSH credentials

  test "saves an SSH key pair for every repository tab", context do
    %{view: view, path: path, base: base} = context
    {private_key, public_key} = ssh_key_pair(base)

    other = Path.join(base, "other")
    File.mkdir_p!(other)
    git!(other, ["init", "--initial-branch=main"])

    open(view, path)
    open(view, other)

    view |> element("#git-ssh-keys") |> render_click()
    assert has_element?(view, "#git-ssh-popover")

    view
    |> form("#git-ssh-form", %{"private_key" => private_key, "public_key" => public_key})
    |> render_submit()

    assert render(view) =~ "SSH ready"
    refute has_element?(view, "#git-ssh-popover")
    assert Preferences.get("git_ssh_private_key") == private_key
    assert Preferences.get("git_ssh_public_key") == public_key

    [first, _second] = tab_ids(view)
    view |> element("#git-tab-#{first}") |> render_click()

    assert render(view) =~ "SSH ready"

    view |> element("#git-ssh-keys") |> render_click()
    assert has_element?(view, "#git-ssh-private-key[value='#{private_key}']")
    assert has_element?(view, "#git-ssh-public-key[value='#{public_key}']")

    view |> element("#git-clear-ssh") |> render_click()
    assert render(view) =~ "SSH keys"
    assert Preferences.get("git_ssh_private_key") == nil
    assert Preferences.get("git_ssh_public_key") == nil
  end

  test "rejects empty SSH key paths", context do
    %{view: view, path: path} = context
    open(view, path)

    view |> element("#git-ssh-keys") |> render_click()

    view
    |> form("#git-ssh-form", %{"private_key" => "", "public_key" => ""})
    |> render_submit()

    assert has_element?(view, "#git-ssh-error")
    assert has_element?(view, "#git-ssh-popover")
    assert render(view) =~ "Private key path cannot be empty"
  end

  test "changes an HTTP remote to SSH from the key settings", context do
    %{view: view, path: path} = context
    git!(path, ["remote", "add", "origin", "https://github.com/example/project.git"])

    git!(path, [
      "remote",
      "set-url",
      "--push",
      "origin",
      "https://github.com/example/project.git"
    ])

    open(view, path)

    view |> element("#git-ssh-keys") |> render_click()

    assert has_element?(view, "#git-ssh-remote-#{slug("origin")}")
    assert has_element?(view, "#git-use-ssh-#{slug("origin")}")
    assert render(view) =~ "SSH keys cannot authenticate this HTTP remote"

    view |> element("#git-use-ssh-#{slug("origin")}") |> render_click()
    render_async(view)

    assert git!(path, ["remote", "get-url", "origin"]) == "git@github.com:example/project.git"

    assert git!(path, ["remote", "get-url", "--push", "origin"]) ==
             "git@github.com:example/project.git"

    refute has_element?(view, "#git-use-ssh-#{slug("origin")}")
    assert view |> element("#git-ssh-remote-kind-#{slug("origin")}") |> render() =~ "ssh"
  end

  ## Snapshot refresh

  test "a mutation made outside the app is picked up by a refresh", context do
    %{view: view, path: path} = context
    open(view, path)

    assert count(view, "#git-commits [role=option]") == 1

    commit_file(path, "outside.txt", "outside\n", "made outside")

    view |> element("#git-refresh") |> render_click()
    render_async(view)

    assert count(view, "#git-commits [role=option]") == 2
    assert render(view) =~ "made outside"
  end

  test "the selection survives a refresh", context do
    %{view: view, path: path, initial_commit: initial} = context
    commit_file(path, "second.txt", "second\n", "second commit")
    open(view, path)

    view |> element("#git-select-commit-#{initial}") |> render_click()

    view |> element("#git-refresh") |> render_click()
    render_async(view)

    assert has_element?(view, "#git-select-commit-#{initial}[aria-selected=true]")
  end

  test "an empty repository renders its panels without commits", context do
    %{view: view, base: base} = context
    empty = Path.join(base, "empty")
    File.mkdir_p!(empty)
    git!(empty, ["init", "--initial-branch=main"])

    open(view, empty)

    assert has_element?(view, "#git-commits-empty")
    assert has_element?(view, "#git-branches-empty")
    assert has_element?(view, "#git-inspector-empty")
  end

  defp slug(value), do: Components.slug(value)
end
