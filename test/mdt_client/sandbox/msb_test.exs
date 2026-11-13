defmodule MDTClient.Sandbox.MsbTest do
  # The runtime folder is application config, so these tests take turns.
  use ExUnit.Case, async: false

  alias MDTClient.Accounts
  alias MDTClient.Sandbox.Msb

  setup do
    saved = Application.get_env(:mdt_client, Msb)
    # A space and a quote, as a home folder may have.
    dir = Path.join(System.tmp_dir!(), "msb test 'runtime' #{System.unique_integer([:positive])}")
    Application.put_env(:mdt_client, Msb, Keyword.put(saved, :runtime_dir, dir))

    on_exit(fn ->
      Application.put_env(:mdt_client, Msb, saved)
      File.rm_rf!(dir)
      File.rm_rf!(Path.dirname(Msb.launcher()))
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

  test "without a runtime there is no msb, and nothing runs" do
    assert Msb.executable() == nil
    assert Msb.run(["ls"]) == {:error, "MDT's msb is missing"}
    assert Msb.write_launcher() == {:error, :no_runtime}
    refute File.exists?(Msb.launcher())
    refute List.keymember?(Msb.env(), "MSB_PATH", 0)
  end

  test "msb runs from MDT's runtime, in MDT's own home", %{dir: dir} do
    msb = fake_runtime(dir)

    assert Msb.executable() == msb
    assert Msb.home() == Path.join(Accounts.root(), "microsandbox")
    assert {:ok, output} = Msb.run(["ls", "--format", "json"])
    assert output == "home=#{Msb.home()} path=#{msb} args=ls --format json\n"
  end

  test "the launcher runs MDT's msb in MDT's home, whatever the caller's environment", %{
    dir: dir
  } do
    msb = fake_runtime(dir)
    assert Msb.write_launcher() == :ok

    assert {output, 0} =
             System.cmd(Msb.launcher(), ["ssh", "serve", "mdt-abc", "--stdio"],
               env: [{"MSB_HOME", "/home/someone/.microsandbox"}, {"MSB_PATH", "/usr/bin/msb"}]
             )

    assert output == "home=#{Msb.home()} path=#{msb} args=ssh serve mdt-abc --stdio\n"
  end

  test "the launcher follows the runtime when an update moves it", %{dir: dir} do
    fake_runtime(dir)
    assert Msb.write_launcher() == :ok
    assert Msb.write_launcher() == :ok

    moved = dir <> " moved"
    on_exit(fn -> File.rm_rf!(moved) end)
    config = Application.get_env(:mdt_client, Msb)
    Application.put_env(:mdt_client, Msb, Keyword.put(config, :runtime_dir, moved))
    msb = fake_runtime(moved)
    assert Msb.write_launcher() == :ok

    assert {output, 0} = System.cmd(Msb.launcher(), ["--version"])
    assert output =~ "path=#{msb} "
  end
end
