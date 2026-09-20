defmodule MDTClientWeb.ToolsLiveTest do
  use MDTClientWeb.ConnCase

  import Phoenix.LiveViewTest

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

  test "opens the HTTP client", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/tools")

    {:ok, tool_view, _html} =
      view
      |> element("#tool-http")
      |> render_click()
      |> follow_redirect(conn, ~p"/tools/http")

    assert has_element?(tool_view, "#request-form")
  end
end
