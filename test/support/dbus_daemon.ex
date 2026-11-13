defmodule MDTClient.DBusDaemon do
  @moduledoc false
  # A private D-Bus bus for a test: dbus-daemon listening on a socket in a
  # short directory of its own (Unix socket paths stop at 108 bytes), killed
  # and removed when the test ends. Tests that need one are tagged :dbus,
  # which test_helper.exs excludes where dbus-daemon isn't installed.

  def available?, do: System.find_executable("dbus-daemon") != nil

  @doc "Starts a bus and returns its address."
  def start! do
    dir = Path.join(System.tmp_dir!(), "mdt-bus-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(dir) end)
    path = Path.join(dir, "bus")

    port =
      Port.open({:spawn_executable, System.find_executable("dbus-daemon")}, [
        :binary,
        :exit_status,
        {:line, 4096},
        args: ["--session", "--nofork", "--print-address", "--address=unix:path=" <> path]
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    ExUnit.Callbacks.on_exit(fn -> System.cmd("kill", ["#{os_pid}"], stderr_to_stdout: true) end)

    receive do
      {^port, {:data, {:eol, address}}} -> %{address: String.trim(address), os_pid: os_pid}
      {^port, {:exit_status, status}} -> raise "dbus-daemon exited with #{status}"
    after
      5_000 -> raise "dbus-daemon didn't print its address"
    end
  end

  @doc "Kills the bus now, as a desktop session ending would."
  def stop(%{os_pid: os_pid}), do: System.cmd("kill", ["#{os_pid}"], stderr_to_stdout: true)
end
