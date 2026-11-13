defmodule MDTClient.Sandbox.ServerCrashTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias MDTClient.Sandbox.{Server, Sockets}
  alias MDTClient.Vault.Store

  setup do
    MDTClient.VaultHelpers.unlocked_identity("crash")
  end

  # Stands in for the relay of a running VM: answers the control socket and
  # tells the test what it was asked. After a stop it is gone, as a relay is.
  defp fake_relay(username) do
    Sockets.ensure!(username)
    path = Sockets.path(username, "control.sock")
    File.rm(path)

    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, ifaddr: {:local, path}, active: false, packet: :line])

    test = self()
    spawn_link(fn -> relay(listen, path, test) end)
    on_exit(fn -> File.rm(path) end)
  end

  defp relay(listen, path, test) do
    {:ok, socket} = :gen_tcp.accept(listen)
    {:ok, line} = :gen_tcp.recv(socket, 0, 5_000)
    word = String.trim(line)
    send(test, {:relay_asked, word})

    if word == "stop" do
      :gen_tcp.send(socket, "stopped\n")
      :gen_tcp.close(socket)
      :gen_tcp.close(listen)
      File.rm(path)
    else
      :gen_tcp.send(socket, "running\n")
      :gen_tcp.close(socket)
      relay(listen, path, test)
    end
  end

  test "a crash leaves the VM running for the restarted sandbox", %{username: username} do
    fake_relay(username)
    pid = running_vm(username)
    ref = Process.monitor(pid)

    # No handler matches, so the sandbox crashes as it would on a bug.
    capture_log(fn ->
      GenServer.cast(pid, :no_handler_matches_this)
      assert_receive {:DOWN, ^ref, :process, ^pid, {:function_clause, _}}
    end)

    # The supervisor has seen the crash and brought the sandbox back.
    _ = :sys.get_state(MDTClient.Vault.DynamicSupervisor)
    assert Store.whereis(Server, username) not in [nil, pid]
    refute_received {:relay_asked, "stop"}
  end

  test "locking stops the VM, cleanly, through its relay", %{username: username} do
    fake_relay(username)
    running_vm(username)
    :ok = Store.close(username)

    assert_received {:relay_asked, "stop"}
  end

  defp running_vm(username) do
    pid = Store.whereis(Server, username)
    :sys.replace_state(pid, &%{&1 | vm: %{&1.vm | exists?: true, status: :running}})
    pid
  end
end
