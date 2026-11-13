defmodule MDTClient.Sandbox.ChannelTest do
  use ExUnit.Case, async: true

  alias MDTClient.Sandbox
  alias MDTClient.Sandbox.{Approval, Channel}

  @cli Path.expand("../../../priv/sandbox/mdt-cli", __DIR__)

  # Stands in for socat on a machine without it: sends stdin to the Unix
  # socket the address names, then prints everything until MDT closes.
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
    bin = Path.join(System.tmp_dir!(), "fake-socat-#{System.unique_integer([:positive])}")
    File.mkdir_p!(bin)
    File.write!(Path.join(bin, "socat"), @fake_socat)
    File.chmod!(Path.join(bin, "socat"), 0o755)
    on_exit(fn -> File.rm_rf!(bin) end)

    "channel" |> MDTClient.VaultHelpers.unlocked_identity() |> Map.put(:bin, bin)
  end

  describe "mdt vm" do
    defp record(context, record, status) do
      server = MDTClient.Vault.Store.whereis(MDTClient.Sandbox.Server, context.username)
      :sys.replace_state(server, &%{&1 | vm_record: record, vm: %{&1.vm | status: status}})
    end

    @made %{id: "3f2a9c1e", created_at: ~U[2026-11-13 20:29:00Z], image: "img:2026-11-13.4"}

    test "says this is the VM MDT runs when the ids match", context do
      record(context, @made, :running)
      assert {0, text} = Channel.answer("vm", %{"id" => "3f2a9c1e"}, context.username)
      assert text =~ "This is the VM MDT runs"
      assert text =~ "vm 3f2a9c1e" and text =~ "2026-11-13 20:29 UTC" and text =~ "2026-11-13.4"
    end

    test "says this is not the VM MDT runs when they don't, or MDT's isn't running", context do
      record(context, @made, :running)
      assert {3, text} = Channel.answer("vm", %{"id" => "00000000"}, context.username)
      assert text =~ "NOT the VM MDT runs" and text =~ "vm 00000000" and text =~ "reconnect"

      record(context, @made, :stopped)
      assert {3, text} = Channel.answer("vm", %{"id" => "3f2a9c1e"}, context.username)
      assert text =~ "it is stopped"
    end

    test "says when there is nothing to compare", context do
      assert {1, text} = Channel.answer("vm", %{"id" => "3f2a9c1e"}, context.username)
      assert text =~ "no record of its VM"

      record(context, %{@made | created_at: nil}, :running)
      assert {1, text} = Channel.answer("vm", %{}, context.username)
      assert text =~ "stop and start the VM" and text =~ "created before MDT kept records"
    end

    test "the mdt command sends the id the boot script wrote", context do
      record(context, @made, :running)
      file = Path.join(context.bin, "mdt-vm")
      File.write!(file, "id=3f2a9c1e\ncreated=2026-11-13T20:29:00Z\n")

      assert {out, 0} = mdt(context, ["vm"], [{"MDT_VM_FILE", file}])
      assert out =~ "This is the VM MDT runs"

      File.write!(file, "id=0badc0de\n")
      assert {out, 3} = mdt(context, ["vm"], [{"MDT_VM_FILE", file}])
      assert out =~ "NOT the VM MDT runs"
    end

    test "the mdt command says what an unanswered check can mean", context do
      file = Path.join(context.bin, "mdt-vm")
      File.write!(file, "id=3f2a9c1e\n")

      assert {out, 4} =
               mdt(context, ["vm"], [
                 {"MDT_VM_FILE", file},
                 {"MDT_CHANNEL", "UNIX-CONNECT:/nonexistent/channel.sock"}
               ])

      assert out =~ "no longer the one MDT runs"
    end
  end

  defp github(username) do
    {:ok, grant} =
      Sandbox.create_grant(username, %{
        "kind" => "token",
        "preset" => "github",
        "name" => "GitHub",
        "purpose" => "Push to oliveigah/klife",
        "hosts" => "api.github.com, github.com",
        "env" => "GH_TOKEN",
        "value" => "ghp_real_value"
      })

    grant
  end

  defp wait_for_ask(username) do
    Enum.find_value(1..200, fn _ ->
      case Sandbox.snapshot(username).waiting do
        [ask | _] -> ask
        [] -> Process.sleep(10) && nil
      end
    end)
  end

  defp mdt(%{username: username, bin: bin}, args), do: mdt(username, bin, args, [])

  defp mdt(%{username: username, bin: bin}, args, env) when is_list(env),
    do: mdt(username, bin, args, env)

  defp mdt(username, bin, args) when is_binary(username), do: mdt(username, bin, args, [])

  # The agent's own variables are cleared: tests may run inside an agent.
  defp mdt(username, bin, args, env) do
    System.cmd("bash", [@cli | args],
      env:
        [
          {"PATH", bin <> ":" <> System.get_env("PATH")},
          {"MDT_CHANNEL", "UNIX-CONNECT:" <> Channel.socket_path(username)},
          {"MDT_AGENT", "codex"},
          {"MDT_THREAD", nil},
          {"CLAUDE_CODE_SESSION_ID", nil},
          {"CLAUDE_PID", nil},
          {"CODEX_THREAD_ID", nil}
        ] ++ env,
      stderr_to_stdout: true
    )
  end

  test "an ask names the thread it came from: Claude Code's title and the agent's folder",
       %{username: username} = context do
    github(username)
    config = Path.join(context.bin, "claude")
    session = "0b5e5e1d-1111-4222-8333-444455556666"
    File.mkdir_p!(Path.join(config, "projects/-work"))

    File.write!(Path.join(config, "projects/-work/#{session}.jsonl"), """
    {"type":"user","message":"hi"}
    {"type":"ai-title","aiTitle":"First guess","sessionId":"#{session}"}
    {"type":"custom-title","customTitle":"Fix the \\"push\\" flow","sessionId":"#{session}"}
    {"type":"ai-title","aiTitle":"Later guess","sessionId":"#{session}"}
    """)

    asking =
      Task.async(fn ->
        mdt(context, ["request", "github", "--reason", "push", "--wait", "0"], [
          {"CLAUDE_CONFIG_DIR", config},
          {"CLAUDE_CODE_SESSION_ID", session},
          {"CLAUDE_PID", System.pid()}
        ])
      end)

    assert {_output, 2} = Task.await(asking)
    ask = wait_for_ask(username)

    # A rename wins over the titles Claude Code makes up; the folder is the
    # agent process's own, not the shell's.
    assert ask.thread == %{title: ~s(Fix the "push" flow), id: session, folder: File.cwd!()}
  end

  test "an ask with no thread to name says so with nil, and MDT_THREAD names one",
       %{username: username} = context do
    github(username)

    assert {_output, 2} =
             mdt(context, ["request", "github", "--reason", "push", "--wait", "0"], [
               {"MDT_THREAD", "Release prep"}
             ])

    ask = wait_for_ask(username)
    assert %{title: "Release prep", id: nil, folder: folder} = ask.thread
    assert is_binary(folder)

    assert Approval.thread(%{}) == nil
    assert Approval.thread(%{thread: "  ", folder: 3}) == nil
    assert Approval.thread(%{thread: "a\nb\e[31m"}).title == "a b [31m"
  end

  test "the socket is the identity's own, short enough for Unix, and only yours", %{
    username: username
  } do
    path = Channel.socket_path(username)
    assert byte_size(path) < 108
    assert %File.Stat{type: :other, mode: mode} = File.stat!(path)
    assert Bitwise.band(mode, 0o077) == 0
  end

  test "asks are checked, and the grants are listed without values", %{username: username} do
    grant = github(username)

    assert {0, text} = Channel.answer("grants", %{}, username)
    assert text =~ "## GitHub"
    assert text =~ "for: Push to oliveigah/klife"
    refute text =~ "ghp_real_value"
    refute text =~ grant.placeholder

    assert {1, text} =
             Channel.answer("request", %{"grant" => "gitlab", "reason" => "x"}, username)

    assert text =~ "mdt request --need"
    assert {1, _} = Channel.answer("request", %{"grant" => "github"}, username)
    assert {1, _} = Channel.answer("fly", %{}, username)

    assert {2, text} =
             Channel.answer(
               "request",
               %{"grant" => "github", "reason" => "push", "wait" => 0},
               username
             )

    [_, id] = Regex.run(~r/mdt wait (\S+)/, text)
    assert [%{kind: :activation, id: ^id}] = Sandbox.snapshot(username).waiting
  end

  test "the mdt command asks, waits, and hears the answer", %{username: username} = context do
    grant = github(username)

    {output, 0} = mdt(context, ["grants"])
    assert output =~ "id: `#{grant.id}`"

    asking =
      Task.async(fn ->
        mdt(context, [
          "request",
          "github",
          "--reason",
          ~s(push "the fix"\nto main),
          "--minutes",
          "20"
        ])
      end)

    ask = wait_for_ask(username)
    assert ask.agent == "codex"
    assert ask.minutes == 20
    assert ask.reason == ~s(push "the fix"\nto main)

    :ok = Sandbox.decide(username, ask.id, {:turn_on, 20, :ask})
    assert {output, 0} = Task.await(asking)
    assert output =~ "GitHub is on until"
    assert output =~ "Each use still waits for the user's approval"

    assert {output, 0} = mdt(context, ["request", "github", "--reason", "again"])
    assert output =~ "already on"
  end

  test "the mdt command reports declines, pending asks and bad asks by exit status",
       %{username: username} = context do
    github(username)

    assert {output, 2} = mdt(context, ["request", "github", "--reason", "r", "--wait", "0"])
    [_, id] = Regex.run(~r/mdt wait (\S+)/, output)

    waiting = Task.async(fn -> mdt(context, ["wait", id]) end)
    _ = wait_for_ask(username)
    Process.sleep(50)
    :ok = Sandbox.decide(username, id, :decline)
    assert {output, 3} = Task.await(waiting)
    assert output =~ "declined"

    assert {_, 1} = mdt(context, ["request", "nothing-like-it", "--reason", "r"])
    assert {_, 1} = mdt(context, ["request"])
    assert {_, 4} = mdt("nobody-unlocked-#{System.unique_integer()}", context.bin, ["grants"])
  end
end
