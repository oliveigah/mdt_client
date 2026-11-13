defmodule MDTClientWeb.DesktopNotificationsLiveTest do
  @moduledoc """
  Desktop notifications from the pages' side: a click brings the window
  forward and opens the approval, which is ringed; the settings page turns
  them on and off.
  """
  use MDTClientWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias MDTClient.Desktop.Notifications
  alias MDTClient.Sandbox
  alias MDTClient.Sandbox.Server

  setup %{conn: conn} do
    sign_in(conn)
  end

  defp ask(username) do
    {:ok, approval} =
      Server.call(
        username,
        {:request_access, %{need: "Postgres on 10.0.0.5", reason: "migrate", agent: "claude"}}
      )

    approval
  end

  defp click(username, path, token) do
    Phoenix.PubSub.broadcast(
      MDTClient.PubSub,
      Notifications.topic(username),
      {:desktop_open, path, token}
    )
  end

  test "a click on any page brings the window forward with the token, then opens the approval",
       %{conn: conn, username: username} do
    approval = ask(username)
    path = "/tools/sandbox/approvals?focus=#{approval.id}"
    {:ok, view, _html} = live(conn, ~p"/tools/notes")

    click(username, path, "wayland-token-1")

    assert_push_event(view, "mdt:present-window", %{token: "wayland-token-1"})
    assert_redirect(view, path)
  end

  test "another identity's clicks don't move this one's pages", %{conn: conn, username: username} do
    {:ok, view, _html} = live(conn, ~p"/tools/notes")
    click(username <> "-someone-else", "/tools/sandbox/approvals", nil)
    refute_push_event(view, "mdt:present-window", %{})
    assert has_element?(view, "#note-list")
  end

  test "the approval a notification opened is ringed and scrolled to; the others aren't", %{
    conn: conn,
    username: username
  } do
    first = ask(username)

    {:ok, other} =
      Server.call(username, {:request_access, %{need: "Redis", reason: "cache", agent: "codex"}})

    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/approvals?focus=#{first.id}")

    assert has_element?(view, "#approval-#{first.id}.ring-2[phx-mounted]")
    refute has_element?(view, "#approval-#{other.id}.ring-2")
    refute has_element?(view, "#approval-#{other.id}[phx-mounted]")
  end

  test "settings turn them off and on, and say why a test can't be sent here", %{
    conn: conn,
    username: username
  } do
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/settings")

    assert has_element?(view, "#desktop-notifications-switch[aria-checked=true]")
    # Tests run without a desktop.
    assert has_element?(view, "#desktop-notifications-status", "without a desktop")
    assert has_element?(view, "#desktop-notifications-test[disabled]")

    view |> element("#desktop-notifications-switch") |> render_click()
    assert has_element?(view, "#desktop-notifications-switch[aria-checked=false]")
    refute Sandbox.snapshot(username).settings.desktop_notifications

    view |> element("#desktop-notifications-switch") |> render_click()
    assert has_element?(view, "#desktop-notifications-switch[aria-checked=true]")
    assert Sandbox.snapshot(username).settings.desktop_notifications
  end

  test "a test notification opens the settings page and goes with it", %{
    conn: conn,
    username: username
  } do
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/settings")
    render_click(view, "test_notification", %{})

    assert [%{notice: %{open: "/tools/sandbox/settings", scope: ^username}}] =
             Enum.filter(Notifications.list(), &(&1.key == {:test, username}))

    ref = Process.monitor(view.pid)
    GenServer.stop(view.pid)
    assert_receive {:DOWN, ^ref, :process, _, _}
    _ = :sys.get_state(Notifications)
    assert Enum.filter(Notifications.list(), &(&1.key == {:test, username})) == []
  end
end
