defmodule MDTClientWeb.SandboxLivePortsTest do
  @moduledoc """
  The VM's ports end to end, with a fake tunnel: forwarding follows the VM,
  the overview shows the address and the ports, agents ask with `mdt ports`.
  Not async: it turns forwarding on in the application's config.
  """
  use MDTClientWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias MDTClient.{Accounts, FakeTunnel}
  alias MDTClient.Sandbox.{Channel, Forwarder, Ports, Server}
  alias MDTClient.Vault.Store

  setup %{conn: conn} do
    agent =
      FakeTunnel.agent(%{
        ss: FakeTunnel.ss([{"127.0.0.1", 4000, "beam.smp"}, {"0.0.0.0", 80, "nginx"}])
      })

    server_config = Application.get_env(:mdt_client, Server, [])
    Application.put_env(:mdt_client, Server, Keyword.put(server_config, :forward_ports, true))

    Application.put_env(:mdt_client, Forwarder,
      tunnel: FakeTunnel,
      opts: [poll_every: 20, reconnect_every: 20, unprivileged_start: 1024]
    )

    Application.put_env(:mdt_client, FakeTunnel, test: self(), agent: agent)

    on_exit(fn ->
      Application.put_env(:mdt_client, Server, server_config)
      Application.delete_env(:mdt_client, Forwarder)
      Application.delete_env(:mdt_client, FakeTunnel)
    end)

    conn |> sign_in() |> Map.put(:agent, agent)
  end

  # msb finishing a start or a stop, as its task would report it.
  defp vm_did(username, action) do
    pid = GenServer.whereis(Store.via(Server, username))
    ref = make_ref()

    :sys.replace_state(pid, fn state ->
      %{
        state
        | tasks: Map.put(state.tasks, ref, {:vm, action}),
          vm: %{state.vm | exists?: true, msb: "/usr/bin/msb"}
      }
    end)

    send(pid, {ref, {:ok, ""}})
    pid
  end

  defp ports(username), do: Server.call(username, :snapshot).ports

  defp until(fun) do
    Enum.find_value(1..300, fn _ -> fun.() || (Process.sleep(10) && nil) end) ||
      flunk("it never happened")
  end

  test "forwarding starts with the VM, shows on the overview and in mdt ports, and stops with it",
       %{conn: conn, username: username} do
    address = Ports.address(Accounts.id(username))

    {:ok, view, _html} = live(conn, ~p"/tools/sandbox")
    assert has_element?(view, "#ports-address", address)
    assert has_element?(view, "#ports-status", "Forwarding starts when the VM runs.")
    assert {0, text} = Channel.answer("ports", %{}, username)
    assert text =~ "Forwarding is off"

    vm_did(username, :start)

    assert_receive {:tunnel, :open, _ref, opts}
    assert opts.vm == Server.vm_name(username)
    assert String.ends_with?(opts.key, "/sandbox/forward_key")
    assert_receive {:tunnel, :forward, ^address, 4000, "127.0.0.1"}
    until(fn -> ports(username).status == :on end)

    until(fn -> has_element?(view, "#port-4000") end)
    assert view |> element("#port-link-4000") |> render() =~ ~s(href="http://#{address}:4000")
    assert has_element?(view, "#port-4000", "beam.smp")
    assert has_element?(view, "#port-skipped-80", "Below 1024")
    refute has_element?(view, "#ports-status")

    assert {0, text} = Channel.answer("ports", %{}, username)
    assert text =~ "The VM's address on the user's machine: #{address}"
    assert text =~ "- 4000: http://#{address}:4000 (beam.smp)"
    assert text =~ "- 80 (nginx): Below 1024"

    assert Server.call(username, :host_text) =~ "http://#{address}:PORT"

    vm_did(username, :stop)

    assert_receive {:tunnel, :close, _ref}
    until(fn -> ports(username).status == :off end)
    assert ports(username).ports == []
    until(fn -> has_element?(view, "#ports-status", "Forwarding starts when the VM runs.") end)
    refute has_element?(view, "#port-4000")
  end

  test "the overview says when nothing listens, and what went wrong", %{
    conn: conn,
    username: username,
    agent: agent
  } do
    FakeTunnel.set(agent, :ss, "")
    vm_did(username, :start)
    until(fn -> ports(username).status == :on end)

    {:ok, view, _html} = live(conn, ~p"/tools/sandbox")
    assert has_element?(view, "#ports-none")
    assert {0, text} = Channel.answer("ports", %{}, username)
    assert text =~ "Nothing listens in the VM yet."

    FakeTunnel.set(agent, :ss, {:error, "ss: command not found"})
    until(fn -> match?({:error, _}, ports(username).status) end)
    until(fn -> has_element?(view, "#ports-status", "ss: command not found") end)
  end

  @tag :capture_log
  test "a forwarder that crashes is replaced", %{username: username} do
    pid = vm_did(username, :start)
    assert_receive {:tunnel, :open, _ref, _opts}
    until(fn -> ports(username).status == :on end)

    forwarder = :sys.get_state(pid).forwarder
    Process.exit(forwarder, :kill)

    until(fn -> ports(username).status == {:error, "Port forwarding stopped"} end)
    assert_receive {:tunnel, :open, _ref, _opts}, 6_000
    until(fn -> ports(username).status == :on end)
    assert :sys.get_state(pid).forwarder not in [nil, forwarder]
  end
end
