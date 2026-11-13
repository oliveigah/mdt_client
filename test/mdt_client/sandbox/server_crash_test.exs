defmodule MDTClient.Sandbox.ServerCrashTest do
  # The msb runtime is application config, so these tests take turns.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias MDTClient.Sandbox.{Msb, Server}
  alias MDTClient.Vault.Store

  setup do
    saved = Application.get_env(:mdt_client, Msb)
    dir = Path.join(System.tmp_dir!(), "msb-crash-#{System.unique_integer([:positive])}")
    calls = Path.join(dir, "calls")

    # A stand-in msb that writes down what it was run with.
    msb = Path.join(dir, "bin/msb")
    File.mkdir_p!(Path.dirname(msb))
    File.write!(msb, "#!/bin/sh\nprintf '%s\\n' \"$*\" >> '#{calls}'\n")
    File.chmod!(msb, 0o755)
    Application.put_env(:mdt_client, Msb, Keyword.put(saved, :runtime_dir, dir))

    on_exit(fn ->
      Application.put_env(:mdt_client, Msb, saved)
      File.rm_rf!(dir)
    end)

    Map.put(MDTClient.VaultHelpers.unlocked_identity("crash"), :calls, calls)
  end

  test "a crash leaves the VM running for the restarted sandbox", %{
    username: username,
    calls: calls
  } do
    pid = running_vm(username)
    ref = Process.monitor(pid)

    # No handler matches, so the sandbox crashes as it would on a bug.
    capture_log(fn ->
      GenServer.cast(pid, :no_handler_matches_this)
      assert_receive {:DOWN, ^ref, :process, ^pid, {:function_clause, _}}
    end)

    refute File.exists?(calls)

    # The supervisor has seen the crash and brought the sandbox back.
    _ = :sys.get_state(MDTClient.Vault.DynamicSupervisor)
    assert Store.whereis(Server, username) not in [nil, pid]
  end

  test "locking stops the VM", %{username: username, calls: calls} do
    running_vm(username)
    :ok = Store.close(username)

    assert File.read!(calls) == "stop #{Server.vm_name(username)}\n"
  end

  defp running_vm(username) do
    pid = Store.whereis(Server, username)
    :sys.replace_state(pid, &%{&1 | vm: %{&1.vm | exists?: true, status: :running}})
    pid
  end
end
