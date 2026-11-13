defmodule MDTClient.Sandbox.MsbTest do
  # The runtime folder is application config, so these tests take turns.
  use ExUnit.Case, async: false

  alias MDTClient.Accounts
  alias MDTClient.Sandbox.{Msb, Sockets}

  doctest MDTClient.Sandbox.Msb

  # Only paths are made from it: no identity needs to exist.
  @user "msb-tester"

  setup do
    saved = Application.get_env(:mdt_client, Msb)
    # A space and a quote, as a home folder may have.
    dir = Path.join(System.tmp_dir!(), "msb test 'runtime' #{System.unique_integer([:positive])}")
    Application.put_env(:mdt_client, Msb, Keyword.put(saved, :runtime_dir, dir))

    on_exit(fn ->
      Application.put_env(:mdt_client, Msb, saved)
      File.rm_rf!(dir)
      File.rm_rf!(Accounts.dir(@user))
      File.rm_rf!(Sockets.dir(@user))
    end)

    %{dir: dir}
  end

  # A stand-in msb that prints what it was run with.
  defp fake_runtime(dir) do
    msb = Path.join(dir, "bin/msb")
    File.mkdir_p!(Path.dirname(msb))
    File.write!(msb, ~S(#!/bin/sh
printf 'home=%s path=%s args=%s\n' "$MSB_HOME" "$MSB_PATH" "$*"
))
    File.chmod!(msb, 0o755)
    msb
  end

  # Holds the relay's lock the way a running relay does, until the test ends.
  defp hold_lock do
    Sockets.ensure!(@user)
    lock = Sockets.path(@user, "relay.lock")
    flock = System.find_executable("flock")
    port = Port.open({:spawn_executable, flock}, [:binary, args: [lock, "sleep", "60"]])
    {:os_pid, pid} = Port.info(port, :os_pid)
    on_exit(fn -> System.cmd("pkill", ["-P", "#{pid}"]) end)

    Enum.find_value(1..200, fn _ ->
      case System.cmd(flock, ["--nonblock", lock, "true"], stderr_to_stdout: true) do
        {_, 0} -> Process.sleep(10) && nil
        {_, _held} -> true
      end
    end) || flunk("the lock was never taken")
  end

  test "without a runtime there is no msb, and nothing runs" do
    assert Msb.executable() == nil
    assert Msb.run(@user, ["ls"]) == {:error, "MDT's msb is missing"}
    assert Msb.write_launcher(@user) == {:error, :no_runtime}
    refute File.exists?(Msb.launcher(@user))
    refute List.keymember?(Msb.env(@user), "MSB_PATH", 0)
  end

  test "msb runs from MDT's runtime, in the identity's own home", %{dir: dir} do
    msb = fake_runtime(dir)

    assert Msb.executable() == msb
    assert Msb.store(@user) == Path.join([Accounts.dir(@user), "sandbox", "microsandbox"])
    refute Msb.store(@user) == Msb.store("someone-else")
    # msb keeps Unix sockets under its home, about 60 bytes deeper, and a
    # socket's path must fit in 108: so its home is a short link.
    assert byte_size(Msb.home(@user)) < 48
    assert {:ok, output} = Msb.run(@user, ["ls", "--format", "json"])
    assert output == "home=#{Msb.home(@user)} path=#{msb} args=ls --format json\n"
    assert File.read_link!(Msb.home(@user)) == Msb.store(@user)
  end

  test "the store and the folders above it are yours alone, whatever umask made them", %{
    dir: dir
  } do
    fake_runtime(dir)
    store = Msb.store(@user)
    above = [store, Path.dirname(store), Accounts.dir(@user), Path.dirname(Accounts.dir(@user))]

    # As a login umask of 002 leaves them, which msb refuses a store under.
    File.mkdir_p!(store)
    for folder <- above, do: File.chmod!(folder, 0o775)

    Msb.ensure_home!(@user)

    for folder <- [Accounts.root() | above] do
      assert Bitwise.band(File.stat!(folder).mode, 0o777) == 0o700, folder
    end
  end

  test "an SSH entry is told apart when it reaches the VM through something else", %{dir: dir} do
    config = Path.join(dir, "ssh_config")

    Application.put_env(
      :mdt_client,
      Msb,
      Keyword.put(Application.get_env(:mdt_client, Msb), :ssh_config, config)
    )

    entry = fn command ->
      "Host mdt-sandbox\n  User root\n  ProxyCommand #{command} ssh serve vm --stdio\n"
    end

    File.mkdir_p!(dir)

    assert Msb.ssh_entry(@user, "mdt-sandbox") == :missing

    File.write!(config, entry.(Msb.launcher(@user)))
    assert Msb.ssh_entry(@user, "mdt-sandbox") == :ok

    # The launcher of the MDT before 2026-11-13, which ran a shared home.
    File.write!(config, entry.("/home/me/.mdt_client/bin/msb"))

    assert Msb.ssh_entry(@user, "mdt-sandbox") ==
             {:other, "/home/me/.mdt_client/bin/msb ssh serve vm --stdio"}

    # ssh takes the first ProxyCommand it finds for the host.
    File.write!(
      config,
      "Host mdt-sandbox other\n  ProxyCommand=nc x 22\n" <> entry.(Msb.launcher(@user))
    )

    assert Msb.ssh_entry(@user, "mdt-sandbox") == {:other, "nc x 22"}

    File.write!(config, "Host something-else\n  ProxyCommand nc x 22\n")
    assert Msb.ssh_entry(@user, "mdt-sandbox") == :missing
  end

  test "the launcher runs MDT's msb in the identity's home, whatever the caller's environment",
       %{dir: dir} do
    msb = fake_runtime(dir)
    assert Msb.write_launcher(@user) == :ok

    assert {output, 0} =
             System.cmd(Msb.launcher(@user), ["ls"],
               env: [{"MSB_HOME", "/home/someone/.microsandbox"}, {"MSB_PATH", "/usr/bin/msb"}]
             )

    assert output == "home=#{Msb.home(@user)} path=#{msb} args=ls\n"
  end

  test "the launcher goes into the VM only while it runs", %{dir: dir} do
    msb = fake_runtime(dir)
    assert Msb.write_launcher(@user) == :ok
    ssh = ["ssh", "serve", "mdt-abc", "--stdio"]

    # msb would boot a stopped VM by itself, outside MDT's bubble.
    assert {output, 1} = System.cmd(Msb.launcher(@user), ssh, stderr_to_stdout: true)
    assert output =~ "isn't running"

    # A lock file nobody holds is a relay that ended.
    Sockets.ensure!(@user)
    File.write!(Sockets.path(@user, "relay.lock"), "")
    assert {_, 1} = System.cmd(Msb.launcher(@user), ssh, stderr_to_stdout: true)

    hold_lock()
    assert {output, 0} = System.cmd(Msb.launcher(@user), ssh, stderr_to_stdout: true)
    assert output == "home=#{Msb.home(@user)} path=#{msb} args=ssh serve mdt-abc --stdio\n"
  end

  test "the launcher won't start, stop or change the VM, running or not", %{dir: dir} do
    fake_runtime(dir)
    assert Msb.write_launcher(@user) == :ok
    hold_lock()

    for word <- ~w(start stop create run restart restore rm modify pull load) do
      assert {output, 1} = System.cmd(Msb.launcher(@user), [word, "x"], stderr_to_stdout: true)
      assert output =~ "msb #{word} isn't available here"
    end
  end

  test "the launcher follows the runtime when an update moves it", %{dir: dir} do
    fake_runtime(dir)
    assert Msb.write_launcher(@user) == :ok
    assert Msb.write_launcher(@user) == :ok

    moved = dir <> " moved"
    on_exit(fn -> File.rm_rf!(moved) end)
    config = Application.get_env(:mdt_client, Msb)
    Application.put_env(:mdt_client, Msb, Keyword.put(config, :runtime_dir, moved))
    msb = fake_runtime(moved)
    assert Msb.write_launcher(@user) == :ok

    assert {output, 0} = System.cmd(Msb.launcher(@user), ["--version"])
    assert output =~ "path=#{msb} "
  end
end
