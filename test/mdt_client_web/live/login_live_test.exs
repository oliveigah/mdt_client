defmodule MDTClientWeb.LoginLiveTest do
  use MDTClientWeb.ConnCase

  import Phoenix.LiveViewTest

  alias MDTClient.Accounts
  alias MDTClient.Preferences
  alias MDTClient.Vault.Store
  alias MDTClient.VaultHelpers

  setup do
    VaultHelpers.reset_data_dir!()
    on_exit(&VaultHelpers.reset_data_dir!/0)
    :ok
  end

  test "an unknown username is announced as a new profile", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/")

    refute html =~ "will be created"

    html =
      view
      |> element("#login-form")
      |> render_change(%{"user" => %{"username" => "oliveigah", "password" => ""}})

    assert html =~ "will be created"
    assert html =~ "Create and unlock"
  end

  test "a known username does not offer to create one", %{conn: conn} do
    {:ok, _profile, _key} = Accounts.sign_in("oliveigah", "correct horse")

    {:ok, view, _html} = live(conn, ~p"/")

    html =
      view
      |> element("#login-form")
      |> render_change(%{"user" => %{"username" => "oliveigah", "password" => ""}})

    refute html =~ "will be created"
    assert html =~ "Unlock"
  end

  test "signing in creates the profile and opens the vault", %{conn: conn} do
    conn = post(conn, ~p"/login", %{"user" => %{"username" => "oliveigah", "password" => "pw"}})

    assert redirected_to(conn) == ~p"/tools"
    assert Accounts.exists?("oliveigah")
    assert Store.open?("oliveigah")
    assert Preferences.get("last_username") == "oliveigah"

    on_exit(fn -> Store.close("oliveigah") end)
  end

  test "the wrong password is refused inline, keeping the username", %{conn: conn} do
    {:ok, _profile, _key} = Accounts.sign_in("oliveigah", "correct horse")

    conn =
      post(conn, ~p"/login", %{"user" => %{"username" => "oliveigah", "password" => "wrong"}})

    refute Store.open?("oliveigah")

    {:ok, view, html} = live(conn, redirected_to(conn))

    assert html =~ "Incorrect password"
    assert has_element?(view, "#login-error")
    assert html =~ ~s(value="oliveigah")
    refute html =~ "will be created"
  end

  test "editing the form clears a stale error", %{conn: conn} do
    {:ok, _profile, _key} = Accounts.sign_in("oliveigah", "correct horse")

    conn =
      post(conn, ~p"/login", %{"user" => %{"username" => "oliveigah", "password" => "wrong"}})

    {:ok, view, _html} = live(conn, redirected_to(conn))

    html =
      view
      |> element("#login-form")
      |> render_change(%{"user" => %{"username" => "oliveigah", "password" => "c"}})

    refute html =~ "Incorrect password"
  end

  test "blank credentials are refused inline", %{conn: conn} do
    conn = post(conn, ~p"/login", %{"user" => %{"username" => "  ", "password" => "pw"}})

    {:ok, _view, html} = live(conn, redirected_to(conn))
    assert html =~ "Enter a username"

    conn = post(build_conn(), ~p"/login", %{"user" => %{"username" => "x", "password" => ""}})

    {:ok, _view, html} = live(conn, redirected_to(conn))
    assert html =~ "Enter a password"
  end

  test "an unknown error code renders nothing", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/?error=%3Cscript%3Ealert(1)%3C/script%3E")

    refute html =~ "login-error"
    refute html =~ "alert(1)"
  end

  test "the login form prefills the last username", %{conn: conn} do
    :ok = Preferences.put("last_username", "oliveigah")

    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ ~s(value="oliveigah")
  end

  test "signing out locks the vault", %{conn: conn} do
    %{conn: conn, username: username} = sign_in(conn)
    assert Store.open?(username)

    conn = delete(conn, ~p"/logout")

    assert redirected_to(conn) == ~p"/"
    refute Store.open?(username)
  end

  test "the tools are unreachable while locked", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/tools/http")
  end

  test "a session whose vault was closed cannot reach the tools", %{conn: conn} do
    %{conn: conn, username: username} = sign_in(conn)
    assert {:ok, _view, _html} = live(conn, ~p"/tools/http")

    :ok = Store.close(username)

    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/tools/http")
  end

  test "the theme toggle is remembered in preferences", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view |> element("[data-phx-theme=dark]") |> render_click()
    assert Preferences.get("theme") == "dark"

    view |> element("[data-phx-theme=system]") |> render_click()
    assert Preferences.get("theme") == "system"
  end

  test "the sign-in screen offers a manual update check", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#check-updates")
  end

  test "an explicit theme is seeded into the page before any script runs", %{conn: conn} do
    :ok = Preferences.put("theme", "light")

    html = conn |> get(~p"/") |> html_response(200)

    assert html =~ ~s(data-theme="light")
    assert html =~ ~s(data-theme-source="user")
  end

  test "the system theme is left to the browser", %{conn: conn} do
    :ok = Preferences.put("theme", "system")

    html = conn |> get(~p"/") |> html_response(200)

    refute html =~ ~s(data-theme="system")
    refute html =~ ~s(data-theme-source=")
  end

  test "two identities cannot see each other's history", %{conn: conn} do
    alias MDTClient.HttpClient.HistoryMetadata
    alias MDTClient.HttpClient.Resources

    %{conn: alice_conn, username: alice} = sign_in(build_conn(), "alice", "same password")

    Resources.record(
      alice,
      HistoryMetadata.new(%{description: "Alice's secret"}),
      Req.new(url: "https://alice.example.test/private"),
      %Req.Response{status: 200, headers: %{}, body: "ok"}
    )

    {:ok, _view, html} = live(alice_conn, ~p"/tools/http")
    assert html =~ "Alice&#39;s secret"

    %{conn: bob_conn} = sign_in(conn, "bob", "same password")
    {:ok, _view, html} = live(bob_conn, ~p"/tools/http")

    refute html =~ "Alice"
    assert html =~ "Nothing here yet"
  end
end
