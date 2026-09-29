defmodule MDTClientWeb.ToolsLiveTest do
  use MDTClientWeb.ConnCase

  import Phoenix.LiveViewTest

  alias MDTClient.VaultHelpers
  alias MDTClient.Updates

  setup %{conn: conn} do
    VaultHelpers.reset_data_dir!()
    on_exit(&VaultHelpers.reset_data_dir!/0)
    sign_in(conn)
  end

  test "lists every tool", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/tools")

    assert has_element?(view, "#tool-http")
    assert has_element?(view, "#tool-git")
  end

  test "the title bar offers the theme toggle", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/tools")

    assert has_element?(view, "[data-phx-theme=system]")
    assert has_element?(view, "[data-phx-theme=light]")
    assert has_element?(view, "[data-phx-theme=dark]")
  end

  test "shows a compact install action when a newer release is announced", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/tools")

    assert has_element?(view, "#check-updates")
    refute has_element?(view, "#update-notice")

    send(
      view.pid,
      {:mdt_update, %{status: :available, release: %{version: "0.6.0"}, message: nil}}
    )

    assert has_element?(view, "#update-notice")
    assert has_element?(view, "#install-update", "Install")
    assert has_element?(view, "#dismiss-update")

    send(
      view.pid,
      {:mdt_update, %{status: :installing, release: %{version: "0.6.0"}, message: nil}}
    )

    assert has_element?(view, "#update-notice")
    refute has_element?(view, "#install-update")
  end

  test "checking is only started by the update button", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/tools")

    refute has_element?(view, "#update-notice")
    view |> element("#check-updates") |> render_click()

    assert has_element?(view, "#update-notice")
    assert has_element?(view, "#update-error")

    view |> element("#dismiss-update") |> render_click()
    refute has_element?(view, "#update-notice")

    on_exit(fn -> Updates.dismiss() end)
  end

  test "the title bar names every tool and marks the one open", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/tools")

    assert has_element?(view, "#tool-switch-http", "HTTP Client")
    assert has_element?(view, "#tool-switch-git", "Git GUI")
    refute has_element?(view, "#tool-switcher [aria-current]")

    {:ok, git_view, _html} = live(conn, ~p"/tools/git")

    assert has_element?(git_view, "#tool-switch-git[aria-current=page]")
    refute has_element?(git_view, "#tool-switch-http[aria-current]")
  end

  test "opens the HTTP client", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/tools")

    {:ok, tool_view, _html} =
      view
      |> element("#tool-http")
      |> render_click()
      |> follow_redirect(conn, ~p"/tools/http")

    assert has_element?(tool_view, "#request-form")
  end

  test "the picker is unreachable while locked" do
    assert {:error, {:redirect, %{to: "/"}}} = live(build_conn(), ~p"/tools")
  end
end
