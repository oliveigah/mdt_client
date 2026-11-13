defmodule MDTClient.Sandbox.HostRunTest do
  use ExUnit.Case, async: true

  alias MDTClient.Sandbox.HostRun

  setup do
    dir = Path.join(System.tmp_dir!(), "host-run-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp run(script, dir, timeout \\ 10) do
    me = self()
    HostRun.run(%{script: script, dir: dir, timeout: timeout}, &send(me, {:group, &1}))
  end

  test "runs in the directory, with stdout and stderr together and its exit status", %{dir: dir} do
    result = run("pwd; echo out; echo err >&2; exit 3", dir)
    assert_received {:group, group} when is_integer(group)
    assert result.exit == 3
    assert result.output == "#{dir}\nout\nerr\n"
    assert result.cut == 0
    refute result.timed_out
    assert result.error == nil
  end

  test "in tests, commands see a home without the login profile of whoever runs them",
       %{dir: dir} do
    home = Application.fetch_env!(:mdt_client, HostRun)[:home]
    assert %{exit: 0, output: ^home} = run(~S(printf %s "$HOME"), dir)
  end

  test "a pipe closed early ends the writer quietly, as in a terminal", %{dir: dir} do
    # Killed by SIGPIPE (141), not left to print "write error: Broken pipe".
    assert %{exit: 0, output: "1\n141 0\n"} =
             run(~S(seq 1 1000000 | head -n 1; echo "${PIPESTATUS[*]}"), dir)
  end

  test "stdin is empty, so a command reading it doesn't hang", %{dir: dir} do
    assert %{exit: 0, output: "0\n"} = run("wc -c", dir)
  end

  test "MDT's and the BEAM's own variables are kept from the command", %{dir: dir} do
    System.put_env("MDT_HOST_RUN_TEST", "secret")
    on_exit(fn -> System.delete_env("MDT_HOST_RUN_TEST") end)

    assert %{output: output} = run("env", dir)
    refute output =~ "MDT_HOST_RUN_TEST"
    refute output =~ "RELEASE_COOKIE"
    refute output =~ "BINDIR="
    assert output =~ "HOME="

    assert HostRun.scrubbed?("RELEASE_COOKIE")
    assert HostRun.scrubbed?("SECRET_KEY_BASE")
    refute HostRun.scrubbed?("PATH")
    refute HostRun.scrubbed?("KUBECONFIG")
  end

  test "a long output keeps its first and last 32 KiB", %{dir: dir} do
    keep = HostRun.keep()
    # 100 KiB of numbered lines.
    result = run("seq 1 20000 | head -c 102400; echo; echo the-end", dir)

    assert result.bytes == 102_400 + 1 + 8
    assert result.cut == result.bytes - 2 * keep
    assert String.starts_with?(result.output, "1\n2\n3\n")
    assert String.ends_with?(result.output, "the-end\n")
    assert result.output =~ "[… #{result.cut} bytes cut …]"
  end

  test "output that isn't UTF-8 is made so", %{dir: dir} do
    assert %{output: output} = run(~S"printf 'a\xff\xfeb'", dir)
    assert String.valid?(output)
    assert output =~ "a"
  end

  test "the time limit ends it with 124, like timeout", %{dir: dir} do
    assert %{exit: 124, timed_out: true} = run("sleep 30", dir, 1)
  end

  test "stopping kills the whole process group", %{dir: dir} do
    me = self()

    task =
      Task.async(fn ->
        HostRun.run(%{script: "sleep 60 & sleep 60; wait", dir: dir, timeout: 120}, fn group ->
          send(me, {:group, group})
        end)
      end)

    assert_receive {:group, group}, 2_000
    # timeout, bash and both sleeps.
    assert Enum.find_value(1..200, fn _ ->
             length(group_pids(group)) >= 4 || (Process.sleep(10) && nil)
           end)

    :ok = HostRun.stop(group, "TERM")

    assert %{exit: exit, timed_out: false} = Task.await(task, 5_000)
    # Some versions of timeout answer 124 to being stopped too.
    assert exit in [124, 137, 143]
    assert group_pids(group) == []
  end

  defp group_pids(group) do
    {out, _} = System.cmd("pgrep", ["-g", Integer.to_string(group)])
    String.split(out, "\n", trim: true)
  end

  test "a directory that doesn't exist is an error, not a crash", %{dir: dir} do
    assert %{exit: nil, error: error} = run("true", Path.join(dir, "missing"))
    assert is_binary(error)
  end
end
