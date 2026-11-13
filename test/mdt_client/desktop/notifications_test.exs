defmodule MDTClient.Desktop.NotificationsTest do
  use ExUnit.Case, async: true

  alias MDTClient.DBus.{Connection, Message}
  alias MDTClient.DBusDaemon
  alias MDTClient.Desktop.Notifications
  alias MDTClient.FakeNotificationService

  defp notice(attrs \\ %{}) do
    Map.merge(
      %{
        summary: "Claude asks to turn on GitHub",
        body: "For 30 min\nReason: “push the fix”",
        scope: "notifications-#{System.unique_integer([:positive])}",
        open: "/tools/sandbox/approvals?focus=ask-1"
      },
      attrs
    )
  end

  defp start(address, opts \\ []) do
    name = :"notifications_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Notifications, Keyword.merge([name: name, address: address, retry_every: 50], opts)}
    )

    name
  end

  defp connected(server) do
    Enum.find_value(1..200, fn _ ->
      case Notifications.status(server) do
        {:connected, _info} = status -> status
        _other -> Process.sleep(10) && nil
      end
    end) || flunk("never connected: #{inspect(Notifications.status(server))}")
  end

  test "without an address it never connects, and still keeps track of what it would show" do
    server = start(nil)
    assert Notifications.status(server) == :off

    Notifications.show(server, :one, notice(%{summary: "  two\n lines  "}))

    assert [%{key: :one, notice: %{summary: "two lines"}, shown?: false}] =
             Notifications.list(server)

    Notifications.close(server, :one)
    assert Notifications.list(server) == []
  end

  test "keeps text the bus accepts and GNOME shows whole" do
    server = start(nil)
    long = String.duplicate("é", 600)
    Notifications.show(server, :bad, notice(%{summary: <<"bad ", 0xFF, 0>>, body: long}))

    [%{notice: %{summary: summary, body: body}}] = Notifications.list(server)
    assert String.valid?(summary) and not String.contains?(summary, <<0>>)
    assert String.length(body) == 400 and String.ends_with?(body, "…")
  end

  describe "on a desktop" do
    @describetag :dbus

    setup do
      bus = DBusDaemon.start!()
      fake = start_supervised!({FakeNotificationService, address: bus.address, test: self()})
      %{bus: bus, fake: fake}
    end

    test "shows a notification as MDT's, with a Review button and the body escaped", %{bus: bus} do
      server = start(bus.address)
      assert {:connected, %{name: "fake-shell", version: "50.0"}} = connected(server)

      Notifications.show(server, :ask, notice(%{body: "a <b>bold</b> & claim"}))
      assert_receive {:notified, 1, notify}

      assert %{
               app_name: "MDT",
               replaces: 0,
               summary: "Claude asks to turn on GitHub",
               body: "a &lt;b&gt;bold&lt;/b&gt; &amp; claim",
               actions: ["default", "Open", "review", "Review"],
               hints: %{"desktop-entry" => {"s", "MDT"}, "urgency" => {"y", 1}}
             } = notify

      assert [%{key: :ask, shown?: true}] = Notifications.list(server)
    end

    test "showing the same key again updates it in place", %{bus: bus} do
      server = start(bus.address)
      connected(server)

      Notifications.show(server, :run, notice(%{summary: "An agent asks to run a command"}))
      assert_receive {:notified, 1, %{replaces: 0}}

      Notifications.show(server, :run, notice(%{summary: "A command's output waits for you"}))
      assert_receive {:notified, 1, %{replaces: 1, summary: "A command's output waits for you"}}
    end

    test "closing a key closes its notification", %{bus: bus} do
      server = start(bus.address)
      connected(server)

      Notifications.show(server, :ask, notice())
      assert_receive {:notified, id, _}
      Notifications.close(server, :ask)
      assert_receive {:closed, ^id}
      assert Notifications.list(server) == []
    end

    test "a click tells the identity's pages what to open, with the click's token", %{
      bus: bus,
      fake: fake
    } do
      server = start(bus.address)
      connected(server)
      notice = notice()
      Notifications.subscribe(notice.scope)

      Notifications.show(server, :ask, notice)
      assert_receive {:notified, id, _}
      FakeNotificationService.click(fake, id, "wayland-token-1")

      assert_receive {:desktop_open, "/tools/sandbox/approvals?focus=ask-1", "wayland-token-1"}
      # GNOME closes a clicked notification, so it is forgotten.
      assert Enum.find_value(1..100, fn _ ->
               Notifications.list(server) == [] or (Process.sleep(10) && false)
             end)
    end

    test "one you dismiss is forgotten: closing its key later does nothing", %{
      bus: bus,
      fake: fake
    } do
      server = start(bus.address)
      connected(server)

      Notifications.show(server, :ask, notice())
      assert_receive {:notified, id, _}
      FakeNotificationService.dismiss(fake, id)

      assert Enum.find_value(1..100, fn _ ->
               Notifications.list(server) == [] or (Process.sleep(10) && false)
             end)

      Notifications.close(server, :ask)
      refute_receive {:closed, _}
    end

    test "notifications close when the process that showed them ends", %{bus: bus} do
      server = start(bus.address)
      connected(server)
      test = self()

      owner =
        spawn(fn ->
          Notifications.show(server, :a, notice())
          Notifications.show(server, :b, notice())
          send(test, :shown)
          receive do: (:stop -> :ok)
        end)

      assert_receive :shown
      assert_receive {:notified, a, _}
      assert_receive {:notified, b, _}
      send(owner, :stop)

      assert_receive {:closed, ^a}
      assert_receive {:closed, ^b}
    end

    test "ignores clicks that don't come from the notification service", %{bus: bus} do
      server = start(bus.address)
      connected(server)
      notice = notice()
      Notifications.subscribe(notice.scope)
      Notifications.show(server, :ask, notice)
      assert_receive {:notified, id, %{sender: mdt}}

      {:ok, impostor} = Connection.start_link(address: bus.address, owner: spawn(fn -> :ok end))

      Connection.send_message(impostor, %Message{
        type: :signal,
        path: "/org/freedesktop/Notifications",
        interface: "org.freedesktop.Notifications",
        member: "ActionInvoked",
        destination: mdt,
        signature: "us",
        body: [id, "default"]
      })

      refute_receive {:desktop_open, _, _}, 200
      assert [%{key: :ask, shown?: true}] = Notifications.list(server)
    end
  end

  describe "before the desktop is ready" do
    @describetag :dbus

    test "with no notification service it says so, and shows what waits once one starts" do
      bus = DBusDaemon.start!()
      server = start(bus.address)

      assert Enum.find_value(1..200, fn _ ->
               match?({:unavailable, _}, Notifications.status(server)) or
                 (Process.sleep(10) && false)
             end)

      assert {:unavailable, "No notification service runs on this desktop."} =
               Notifications.status(server)

      Notifications.show(server, :early, notice(%{summary: "Waiting since before"}))
      assert [%{key: :early, shown?: false}] = Notifications.list(server)

      start_supervised!({FakeNotificationService, address: bus.address, test: self()})
      assert_receive {:notified, 1, %{summary: "Waiting since before"}}, 2_000
      assert {:connected, _} = Notifications.status(server)
    end

    test "when the bus goes away it keeps what it shows, and says why" do
      bus = DBusDaemon.start!()
      # It goes down with the bus.
      start_supervised!(
        Supervisor.child_spec({FakeNotificationService, address: bus.address, test: self()},
          restart: :temporary
        )
      )

      server = start(bus.address, retry_every: 60_000)
      connected(server)
      Notifications.show(server, :ask, notice())
      assert_receive {:notified, _, _}

      DBusDaemon.stop(bus)

      assert Enum.find_value(1..200, fn _ ->
               match?({:unavailable, _}, Notifications.status(server)) or
                 (Process.sleep(10) && false)
             end)

      assert [%{key: :ask, shown?: false}] = Notifications.list(server)
    end
  end
end
