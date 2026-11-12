defmodule MDTClient.Sandbox.ChannelTest do
  use ExUnit.Case, async: true

  alias MDTClient.Sandbox
  alias MDTClient.Sandbox.Channel

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

  defp mdt(%{username: username, bin: bin}, args), do: mdt(username, bin, args)

  defp mdt(username, bin, args) do
    System.cmd("bash", [@cli | args],
      env: [
        {"PATH", bin <> ":" <> System.get_env("PATH")},
        {"MDT_CHANNEL", "UNIX-CONNECT:" <> Channel.socket_path(username)},
        {"MDT_AGENT", "codex"}
      ],
      stderr_to_stdout: true
    )
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
