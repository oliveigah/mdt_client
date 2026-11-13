defmodule MDTClient.Sandbox.ServerNotificationsTest do
  @moduledoc """
  The sandbox keeps one desktop notification per approval waiting for you.
  The app's notification service never connects in tests, but keeps track
  of what it would show, which is what these read.
  """
  use ExUnit.Case, async: true

  alias MDTClient.Desktop.Notifications
  alias MDTClient.Sandbox
  alias MDTClient.Sandbox.Server

  setup do
    context = MDTClient.VaultHelpers.unlocked_identity("notify")

    {:ok, grant} =
      Sandbox.create_grant(context.username, %{
        "kind" => "token",
        "preset" => "github",
        "name" => "GitHub",
        "purpose" => "Push to oliveigah/klife",
        "hosts" => "api.github.com, github.com",
        "env" => "GH_TOKEN",
        "value" => "ghp_real_value"
      })

    Map.put(context, :grant, grant)
  end

  # What the service shows for this identity, by approval id.
  defp shown(username) do
    _ = :sys.get_state(Notifications)

    for %{key: {:sandbox, ^username, id}, notice: notice} <- Notifications.list(),
        into: %{},
        do: {id, notice}
  end

  defp ask(username, grant) do
    {:ok, approval} =
      Server.call(
        username,
        {:request_access,
         %{grant: grant.id, minutes: 30, reason: "push the fix", agent: "claude"}}
      )

    approval
  end

  test "an agent's ask shows until you decide it", %{username: username, grant: grant} do
    approval = ask(username, grant)

    assert %{summary: "Claude asks to turn on GitHub", open: open, scope: ^username} =
             shown(username)[approval.id]

    assert open == "/tools/sandbox/approvals?focus=#{approval.id}"

    :ok = Sandbox.decide(username, approval.id, :decline)
    assert shown(username) == %{}
  end

  test "asking again joins the waiting ask without a second notification", %{
    username: username,
    grant: grant
  } do
    first = ask(username, grant)
    again = ask(username, grant)
    assert again.id == first.id
    assert Map.keys(shown(username)) == [first.id]
  end

  test "turning notifications off closes them; on again shows what still waits", %{
    username: username,
    grant: grant
  } do
    approval = ask(username, grant)

    {:ok, %{desktop_notifications: false}} =
      Sandbox.update_settings(username, %{"desktop_notifications" => "false"})

    assert shown(username) == %{}

    other =
      Server.call(
        username,
        {:request_access, %{need: "Postgres", reason: "migrate", agent: "codex"}}
      )

    assert {:ok, _} = other
    assert shown(username) == %{}

    {:ok, _} = Sandbox.update_settings(username, %{"desktop_notifications" => "true"})

    assert shown(username) |> Map.keys() |> Enum.sort() ==
             Enum.sort([approval.id, elem(other, 1).id])

    assert {:error, %{desktop_notifications: _}} =
             Sandbox.update_settings(username, %{"desktop_notifications" => "maybe"})
  end

  test "a command shows while it waits, and again when its output waits for you", %{
    username: username
  } do
    {:ok, grant} =
      Sandbox.create_grant(username, %{
        "kind" => "command",
        "name" => "shell",
        "purpose" => "Run commands on this machine"
      })

    {:ok, _} = Sandbox.turn_on(username, grant.id, :until_off, :ask)

    {:ok, approval} =
      Server.call(
        username,
        {:request_command,
         %{grant: "shell", script: "echo hi", timeout: 10, reason: "check", agent: "claude"}}
      )

    assert %{summary: "Claude asks to run a command on this machine"} =
             shown(username)[approval.id]

    # Running, it waits for nobody; done, its output waits for you.
    :ok = Sandbox.decide(username, approval.id, {:run, :review})

    output =
      Enum.find_value(1..300, fn _ ->
        case shown(username)[approval.id] do
          %{summary: "A command's output waits for you"} = notice -> notice
          _other -> Process.sleep(10) && nil
        end
      end)

    assert output.body =~ "echo hi\nExit 0"

    :ok = Sandbox.decide(username, approval.id, :keep_output)
    assert shown(username) == %{}
  end

  test "locking the vault closes the identity's notifications", %{
    username: username,
    grant: grant
  } do
    ask(username, grant)
    assert map_size(shown(username)) == 1

    pid = GenServer.whereis(MDTClient.Vault.Store.via(Server, username))
    ref = Process.monitor(pid)
    MDTClient.Vault.Store.close(username)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}

    assert shown(username) == %{}
  end
end
