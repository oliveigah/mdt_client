defmodule MDTClientWeb.LoginLiveTest do
  use MDTClientWeb.ConnCase

  import Phoenix.LiveViewTest

  test "the app boots to the login screen", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#login-form")
    assert has_element?(view, "#user_email")
    assert has_element?(view, "#user_password")
    assert has_element?(view, "#sign-in")
  end

  test "the login screen can switch themes", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "[data-phx-theme=light]")
    assert has_element?(view, "[data-phx-theme=dark]")
  end

  test "requires a password", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> form("#login-form", user: %{email: "dev@mdt.local", password: ""})
    |> render_submit()

    assert has_element?(view, "#login-error")
  end

  test "signing in opens the tool picker", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert {:error, {:live_redirect, %{to: "/tools"}}} =
             view
             |> form("#login-form", user: %{email: "dev@mdt.local", password: "secret"})
             |> render_submit()
  end
end
