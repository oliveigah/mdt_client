defmodule MDTClient.Sandbox.HostCommandChannelTest do
  @moduledoc """
  Host commands end to end: the `mdt` command in the VM (here, with a fake
  socat), the channel, the server's approval, the run on this machine, and
  what the agent hears back.
  """
  use ExUnit.Case, async: true

  alias MDTClient.Sandbox
  alias MDTClient.Sandbox.Channel

  @cli Path.expand("../../../priv/sandbox/mdt-cli", __DIR__)

  # Stands in for socat: sends stdin to the Unix socket the address names,
  # then prints everything until MDT closes.
  @fake_socat """
  #!/usr/bin/env python3
  import socket, sys
  address = sys.argv[-1]
  assert address.startswith("UNIX-CONNECT:"), address
  data = sys.stdin.buffer.read()
  s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
  s.connect(address[len("UNIX-CONNECT:"):])
  s.sendall(data)
  while True:
      chunk = s.recv(65536)
      if not chunk:
          break
      sys.stdout.buffer.write(chunk)
  """

  setup do
    base = Path.join(System.tmp_dir!(), "mdt-run-#{System.unique_integer([:positive])}")
    bin = Path.join(base, "bin")
    project = Path.join(base, "project")
    File.mkdir_p!(bin)
    File.mkdir_p!(project)
    File.write!(Path.join(bin, "socat"), @fake_socat)
    File.chmod!(Path.join(bin, "socat"), 0o755)
    on_exit(fn -> File.rm_rf!(base) end)

    "commands"
    |> MDTClient.VaultHelpers.unlocked_identity()
    |> Map.merge(%{bin: bin, project: project})
  end

  defp mdt(context, args, opts \\ []) do
    {input, opts} = Keyword.pop(opts, :input)

    env = [
      {"PATH", context.bin <> ":" <> System.get_env("PATH")},
      {"MDT_CHANNEL", "UNIX-CONNECT:" <> Channel.socket_path(context.username)},
      {"MDT_AGENT", "claude"},
      {"MDT_THREAD", "Ship the release"},
      {"CLAUDE_CODE_SESSION_ID", nil},
      {"CLAUDE_PID", nil},
      {"CODEX_THREAD_ID", nil}
    ]

    if input do
      # A script on stdin: run through a shell so the CLI's stdin is a pipe.
      script_file = Path.join(context.bin, "stdin-#{System.unique_integer([:positive])}")
      File.write!(script_file, input)
      quoted = Enum.map_join([@cli | args], " ", &shell_quote/1)

      System.cmd("bash", ["-c", "bash #{quoted} < #{shell_quote(script_file)}"],
        env: env,
        cd: Keyword.get(opts, :cd, context.project)
      )
    else
      System.cmd("bash", [@cli | args],
        env: env,
        cd: Keyword.get(opts, :cd, context.project),
        stderr_to_stdout: Keyword.get(opts, :stderr, true)
      )
    end
  end

  defp shell_quote(word), do: "'" <> String.replace(word, "'", "'\\''") <> "'"

  defp waiting(username, fun) do
    Enum.find_value(1..300, fn _ ->
      case Enum.find(Sandbox.snapshot(username).waiting, fun) do
        nil -> Process.sleep(10) && nil
        approval -> approval
      end
    end) || flunk("nothing like that waited")
  end

  defp command(username), do: waiting(username, &(&1.kind == :command and &1.stage == :run))

  defp output_card(username),
    do: waiting(username, &(&1.kind == :command and &1.stage == :output))

  defp share(context) do
    {:ok, share} = Sandbox.add_share(context.username, context.project, :rw)
    share.path
  end

  test "mdt host describes this machine and the shares", context do
    shared = share(context)
    {:ok, _} = Sandbox.update_settings(context.username, %{"host_notes" => "VPN: openvpn3 work"})

    {output, 0} = mdt(context, ["host"])
    assert output =~ "# The user's machine"
    assert output =~ "Architecture: #{:erlang.system_info(:system_architecture)}"
    assert output =~ "- #{shared} (read-write in the VM)"
    assert output =~ "VPN: openvpn3 work"

    inbox = Sandbox.snapshot(context.username).inbox
    assert File.read!(Path.join(inbox, "host.md")) == String.trim_trailing(output) <> "\n"
  end

  test "an approved command runs in the shared folder, and its status and output come back",
       context do
    shared = share(context)
    File.write!(Path.join(shared, "input.txt"), "from the VM\n")

    asking =
      Task.async(fn ->
        mdt(context, ["run", "--reason", "read the input", "--", "cat input.txt; pwd; exit 7"],
          stderr: false
        )
      end)

    approval = command(context.username)
    assert approval.script == "cat input.txt; pwd; exit 7"
    assert approval.dir == shared
    assert approval.agent == "claude"
    assert %{title: "Ship the release", id: nil, folder: folder} = approval.thread
    assert is_binary(folder)
    assert approval.claims == [{"Reason", "read the input"}]
    assert approval.id =~ ~r/^run-/

    :ok = Sandbox.decide(context.username, approval.id, {:run, :send})
    assert {output, 7} = Task.await(asking, 10_000)
    assert output == "from the VM\n#{shared}\n"

    [decided] = Sandbox.snapshot(context.username).history
    assert decided.run.exit == 7
    assert decided.decision == {:run, :send}
  end

  test "several arguments are quoted for the shell; one is a shell line; none reads stdin",
       context do
    asking =
      Task.async(fn ->
        mdt(context, ["run", "--reason", "r", "printf", "%s|", "a b", "c;d", "$HOME"],
          stderr: false
        )
      end)

    approval = command(context.username)
    :ok = Sandbox.decide(context.username, approval.id, {:run, :send})
    assert {"a b|c;d|$HOME|", 0} = Task.await(asking, 10_000)

    asking =
      Task.async(fn -> mdt(context, ["run", "--reason", "r"], input: "echo one\necho two\n") end)

    approval = command(context.username)
    assert approval.script == "echo one\necho two"
    :ok = Sandbox.decide(context.username, approval.id, {:run, :send})
    assert {"one\ntwo\n", 0} = Task.await(asking, 10_000)

    # Output keeps its trailing newlines, or their absence.
    asking =
      Task.async(fn ->
        mdt(context, ["run", "--reason", "r", "--", "printf 'x\\n\\n\\n'"], stderr: false)
      end)

    approval = command(context.username)
    :ok = Sandbox.decide(context.username, approval.id, {:run, :send})
    assert {"x\n\n\n", 0} = Task.await(asking, 10_000)
  end

  test "outside a share it runs in the home folder", context do
    asking =
      Task.async(fn -> mdt(context, ["run", "--reason", "r", "--", "pwd"], stderr: false) end)

    approval = command(context.username)
    assert approval.dir == System.user_home!()
    :ok = Sandbox.decide(context.username, approval.id, {:run, :send})
    assert {output, 0} = Task.await(asking, 10_000)
    assert output == System.user_home!() <> "\n"
  end

  test "the output can wait for you, who send it or keep it", context do
    {output, 120} = mdt(context, ["run", "--reason", "r", "--wait", "0", "--", "echo secret"])
    [_, id] = Regex.run(~r/mdt wait (run-\S+)/, output)

    :ok = Sandbox.decide(context.username, id, {:run, :review})
    card = output_card(context.username)
    assert card.id == id
    assert card.run.output == "secret\n"
    assert card.run.exit == 0

    {output, 120} = mdt(context, ["wait", id, "--wait", "0"])
    assert output =~ "looking at its output"

    # Whether the wait arrives before or after the decision, it gets the output.
    waiting = Task.async(fn -> mdt(context, ["wait", id], stderr: false) end)
    :ok = Sandbox.decide(context.username, id, :send_output)
    assert {"secret\n", 0} = Task.await(waiting, 10_000)

    # Kept: the agent hears it ran, not what it printed.
    asking =
      Task.async(fn -> mdt(context, ["run", "--reason", "r", "--", "echo hidden; exit 3"]) end)

    approval = command(context.username)
    :ok = Sandbox.decide(context.username, approval.id, {:run, :review})
    card = output_card(context.username)
    :ok = Sandbox.decide(context.username, card.id, :keep_output)
    assert {output, 121} = Task.await(asking, 10_000)
    assert output =~ "It ran (exit 3), but the user kept its output"
    refute output =~ "hidden"
  end

  test "an output nobody releases is kept; the first wait's timer doesn't end the second",
       context do
    server = MDTClient.Vault.Store.whereis(MDTClient.Sandbox.Server, context.username)
    {_, 120} = mdt(context, ["run", "--reason", "r", "--wait", "0", "--", "echo private"])
    asked = command(context.username)
    :ok = Sandbox.decide(context.username, asked.id, {:run, :review})
    card = output_card(context.username)
    assert DateTime.compare(card.deadline, asked.deadline) != :lt

    # A timer set for an earlier deadline, like the one from when it was
    # asked, leaves the output waiting.
    send(server, {:give_up, card.id, DateTime.add(card.deadline, -1, :second)})
    _ = :sys.get_state(server)
    assert output_card(context.username).id == card.id

    send(server, {:give_up, card.id, card.deadline})
    {output, 121} = mdt(context, ["wait", card.id])
    assert output =~ "didn't release its output"
    refute output =~ "private"
  end

  test "a declined command doesn't run", context do
    marker = Path.join(context.project, "ran")

    asking =
      Task.async(fn -> mdt(context, ["run", "--reason", "r", "--", "touch #{marker}"]) end)

    approval = command(context.username)
    :ok = Sandbox.decide(context.username, approval.id, :decline)
    assert {output, 121} = Task.await(asking, 10_000)
    assert output =~ "declined"
    refute File.exists?(marker)
    assert {:error, :not_waiting} = Sandbox.decide(context.username, approval.id, {:run, :send})
  end

  test "commands accept only their own decisions", context do
    {_, 120} = mdt(context, ["run", "--reason", "r", "--wait", "0", "--", "true"])
    approval = command(context.username)

    for decision <- [
          :allow_once,
          {:allow, :similar, 10},
          {:allow, :all, :grant},
          :send_output,
          {:run, :forever}
        ] do
      assert {:error, :bad_decision} = Sandbox.decide(context.username, approval.id, decision)
    end
  end

  test "the same command asked again joins the waiting one", context do
    {_, 120} = mdt(context, ["run", "--reason", "r", "--wait", "0", "--", "date"])
    {_, 120} = mdt(context, ["run", "--reason", "again", "--wait", "0", "--", "date"])

    {_, 120} =
      mdt(context, ["run", "--reason", "r", "--wait", "0", "--timeout", "5", "--", "date"])

    waiting = Sandbox.snapshot(context.username).waiting
    assert [%{retries: 1}, %{retries: 0}] = Enum.sort_by(waiting, & &1.retries, :desc)
  end

  test "a running command can be stopped", context do
    asking =
      Task.async(fn ->
        mdt(context, ["run", "--reason", "r", "--wait", "30", "--", "echo started; sleep 60"])
      end)

    approval = command(context.username)
    :ok = Sandbox.decide(context.username, approval.id, {:run, :send})

    running =
      Enum.find_value(1..300, fn _ ->
        case Sandbox.snapshot(context.username).running do
          [running] -> running
          [] -> Process.sleep(10) && nil
        end
      end)

    assert running.id == approval.id
    :ok = Sandbox.stop_command(context.username, approval.id)

    assert {output, status} = Task.await(asking, 10_000)
    assert status in [124, 137, 143]
    assert output =~ "the user stopped it"
    assert {:error, :not_running} = Sandbox.stop_command(context.username, approval.id)
    assert Sandbox.snapshot(context.username).running == []
  end

  test "wrong asks and an unreachable MDT have their own statuses", context do
    assert {output, 122} = mdt(context, ["run", "--", "true"])
    assert output =~ "Say why"
    assert {_, 122} = mdt(context, ["run", "--reason", "r", "--timeout", "0", "--", "true"])
    assert {_, 122} = mdt(context, ["run", "--reason", "r", "--timeout", "x", "--", "true"])
    assert {_, 122} = mdt(context, ["run", "--reason", "r", "--bogus", "--", "true"])

    assert {output, 122} =
             mdt(context, ["run", "--reason", "r", "--", String.duplicate("x", 16_385)])

    assert output =~ "16 KiB"

    unreachable = %{context | username: "nobody-#{System.unique_integer([:positive])}"}
    assert {_, 123} = mdt(unreachable, ["run", "--reason", "r", "--", "true"])
    assert {_, 123} = mdt(unreachable, ["wait", "run-abc"])
    assert {_, 4} = mdt(unreachable, ["wait", "ask-abc"])
  end

  test "status dumps and crash reports never carry a command's output", context do
    asking =
      Task.async(fn -> mdt(context, ["run", "--reason", "r", "--", "echo dump-$((6 * 7))"]) end)

    approval = command(context.username)
    :ok = Sandbox.decide(context.username, approval.id, {:run, :send})
    {"dump-42\n", 0} = Task.await(asking, 10_000)

    server = MDTClient.Vault.Store.whereis(MDTClient.Sandbox.Server, context.username)
    status = :sys.get_status(server)
    refute inspect(status, limit: :infinity, printable_limit: :infinity) =~ "dump-42"
  end

  test "the activity log says what happened, never the output", context do
    asking =
      Task.async(fn ->
        mdt(context, ["run", "--reason", "r", "--", "echo top-secret-$((40 + 2))"])
      end)

    approval = command(context.username)
    :ok = Sandbox.decide(context.username, approval.id, {:run, :send})
    {_, 0} = Task.await(asking, 10_000)

    events = Sandbox.events(context.username, %{group: "commands"})
    summaries = Enum.map(events, & &1.summary)
    assert Enum.any?(summaries, &(&1 =~ "you ran it, output to the agent"))
    assert Enum.any?(summaries, &(&1 =~ "exit 0"))
    refute Enum.any?(summaries, &(&1 =~ "top-secret-42"))
  end
end
