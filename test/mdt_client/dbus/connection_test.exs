defmodule MDTClient.DBus.ConnectionTest do
  use ExUnit.Case, async: true

  alias MDTClient.DBus.{Connection, Message}
  alias MDTClient.DBusDaemon

  doctest Connection

  @bus "org.freedesktop.DBus"

  defp bus_call(member, signature \\ "", body \\ []),
    do: Message.call(@bus, "/org/freedesktop/DBus", @bus, member, signature, body)

  test "reads Unix addresses, path or abstract, escaped or not, and skips others" do
    assert Connection.socket_address("unix:path=/run/user/1000/bus,guid=abc") ==
             {:ok, {:local, "/run/user/1000/bus"}}

    assert Connection.socket_address("tcp:host=x,port=1;unix:abstract=/tmp/dbus-a%2cb") ==
             {:ok, {:local, <<0, "/tmp/dbus-a,b">>}}

    assert Connection.socket_address("tcp:host=localhost,port=1") ==
             {:error, :unsupported_address}
  end

  test "can't connect where there is no bus" do
    Process.flag(:trap_exit, true)

    assert {:error, {:connect, _}} =
             Connection.start_link(address: "unix:path=/nonexistent/mdt-bus")
  end

  describe "on a bus" do
    @describetag :dbus

    setup do
      %{bus: DBusDaemon.start!()}
    end

    test "authenticates, says Hello and gets a unique name", %{bus: bus} do
      {:ok, conn} = Connection.start_link(address: bus.address)
      assert ":" <> _ = name = Connection.unique_name(conn)

      assert {:ok, %Message{body: [names]}} = Connection.call(conn, bus_call("ListNames"))
      assert name in names
    end

    test "returns D-Bus errors as errors", %{bus: bus} do
      {:ok, conn} = Connection.start_link(address: bus.address)

      assert {:error, {:dbus, "org.freedesktop.DBus.Error.NameHasNoOwner", text}} =
               Connection.call(conn, bus_call("GetNameOwner", "s", ["org.nobody"]))

      assert text =~ "org.nobody"
    end

    test "passes signals and calls addressed to it to its owner", %{bus: bus} do
      {:ok, conn} = Connection.start_link(address: bus.address)
      {:ok, other} = Connection.start_link(address: bus.address, owner: spawn(fn -> :ok end))
      me = Connection.unique_name(conn)

      :ok =
        Connection.send_message(other, %Message{
          type: :signal,
          path: "/x",
          interface: "org.example.Test",
          member: "Poke",
          destination: me,
          signature: "us",
          body: [7, "hi"]
        })

      assert_receive {:dbus_signal, ^conn, %Message{member: "Poke", body: [7, "hi"]}}

      :ok =
        Connection.send_message(other, %{
          Message.call(me, "/x", "org.example.Test", "Hello", "s", ["there"])
          | flags: [:no_reply_expected]
        })

      assert_receive {:dbus_method_call, ^conn, %Message{member: "Hello", body: ["there"]}}
    end

    test "gives up on a call nobody answers, and carries on", %{bus: bus} do
      {:ok, conn} = Connection.start_link(address: bus.address)
      # Its owner never answers the calls it is given.
      owner = spawn(fn -> Process.sleep(:infinity) end)
      {:ok, quiet} = Connection.start_link(address: bus.address, owner: owner)
      quiet_name = Connection.unique_name(quiet)

      assert {:error, :timeout} =
               Connection.call(conn, Message.call(quiet_name, "/x", "org.example.T", "Wait"), 100)

      assert {:ok, _} = Connection.call(conn, bus_call("ListNames"))
    end

    test "refuses a message whose values don't fit, without dropping the connection", %{
      bus: bus
    } do
      {:ok, conn} = Connection.start_link(address: bus.address)

      assert {:error, {:invalid, _}} =
               Connection.call(conn, bus_call("GetNameOwner", "s", [<<0xFF>>]))

      assert {:ok, _} = Connection.call(conn, bus_call("ListNames"))
    end

    test "stops when the bus goes away, and its starter hears", %{bus: bus} do
      Process.flag(:trap_exit, true)
      {:ok, conn} = Connection.start_link(address: bus.address)
      DBusDaemon.stop(bus)
      assert_receive {:EXIT, ^conn, {:shutdown, :closed}}, 2_000
    end
  end
end
