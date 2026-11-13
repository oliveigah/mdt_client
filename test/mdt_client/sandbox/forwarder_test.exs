defmodule MDTClient.Sandbox.ForwarderTest do
  use ExUnit.Case, async: true

  alias MDTClient.FakeTunnel
  alias MDTClient.Sandbox.Forwarder

  # A loopback address nothing else here uses: when a forward fails, the
  # forwarder tries listening on it to find out why.
  @address "127.77.231.17"

  setup do
    %{agent: FakeTunnel.agent()}
  end

  defp start(agent, opts \\ []) do
    start_supervised!(
      {Forwarder,
       Keyword.merge(
         [
           report_to: self(),
           address: @address,
           tunnel: FakeTunnel,
           tunnel_opts: %{test: self(), agent: agent},
           unprivileged_start: 1024,
           poll_every: 20,
           reconnect_every: 20,
           retry_after: 150
         ],
         opts
       )}
    )
  end

  # Reports until one matches.
  defp report(pred, timeout \\ 2_000) do
    receive do
      {:ports, _pid, snapshot} -> if pred.(snapshot), do: snapshot, else: report(pred, timeout)
    after
      timeout -> flunk("no matching report")
    end
  end

  defp entry(snapshot, port), do: Enum.find(snapshot.ports, &(&1.port == port))

  test "forwards what listens in the VM to the same port here, and says what holds it", %{
    agent: agent
  } do
    FakeTunnel.set(
      agent,
      :ss,
      FakeTunnel.ss([
        {"127.0.0.1", 4000, "beam.smp"},
        {"0.0.0.0", 5173, "node"},
        {"[::1]", 8080, "python3"},
        {"0.0.0.0", 80, "nginx"}
      ])
    )

    start(agent)
    assert_receive {:ports, _, %{status: :connecting}}
    assert_receive {:tunnel, :open, _ref, _opts}

    snapshot = report(&(&1.status == :on))
    assert_received {:tunnel, :forward, @address, 4000, "127.0.0.1"}
    assert_received {:tunnel, :forward, @address, 5173, "127.0.0.1"}
    assert_received {:tunnel, :forward, @address, 8080, "::1"}
    refute_received {:tunnel, :forward, _, 80, _}

    assert %{status: :forwarded, process: "beam.smp", target: "127.0.0.1"} = entry(snapshot, 4000)
    assert %{status: :forwarded, target: "::1"} = entry(snapshot, 8080)
    assert %{status: {:skipped, "Below 1024" <> _}, process: "nginx"} = entry(snapshot, 80)

    # Nothing changed, nothing more is said or done.
    refute_receive {:ports, _, _}, 150
    refute_received {:tunnel, :forward, _, _, _}
  end

  test "a server that stops loses its forward, and a new one gets one", %{agent: agent} do
    FakeTunnel.set(agent, :ss, FakeTunnel.ss([{"127.0.0.1", 4000, "beam.smp"}]))
    start(agent)
    report(&(entry(&1, 4000) && entry(&1, 4000).status == :forwarded))

    FakeTunnel.set(agent, :ss, FakeTunnel.ss([{"127.0.0.1", 4001, "beam.smp"}]))
    snapshot = report(&(entry(&1, 4001) != nil))

    assert_received {:tunnel, :cancel, @address, 4000, "127.0.0.1"}
    assert_received {:tunnel, :forward, @address, 4001, "127.0.0.1"}
    assert entry(snapshot, 4000) == nil
  end

  test "a port this machine already holds is listed with why, and tried again later", %{
    agent: agent
  } do
    {:ok, ip} = :inet.parse_address(String.to_charlist(@address))
    {:ok, taken} = :gen_tcp.listen(0, ip: ip)
    {:ok, port} = :inet.port(taken)

    FakeTunnel.set(agent, :ss, FakeTunnel.ss([{"127.0.0.1", port, "beam.smp"}]))
    FakeTunnel.set(agent, :fail, %{port => "Port forwarding failed"})
    start(agent)

    snapshot = report(&match?(%{status: {:skipped, _}}, entry(&1, port)))
    assert entry(snapshot, port).status == {:skipped, "Something on this machine already uses it"}
    assert_received {:tunnel, :forward, @address, ^port, "127.0.0.1"}

    # Not tried on every listing, but again once its wait is over.
    refute_receive {:tunnel, :forward, _, ^port, _}, 80
    :gen_tcp.close(taken)
    FakeTunnel.set(agent, :fail, %{})

    assert_receive {:tunnel, :forward, @address, ^port, "127.0.0.1"}, 1_000
    report(&(entry(&1, port).status == :forwarded))
  end

  test "a forward the tunnel refuses for another reason says what the tunnel said", %{
    agent: agent
  } do
    FakeTunnel.set(agent, :ss, FakeTunnel.ss([{"127.0.0.1", 4999, "beam.smp"}]))
    FakeTunnel.set(agent, :fail, %{4999 => "administratively prohibited"})
    start(agent)

    snapshot = report(&match?(%{status: {:skipped, _}}, entry(&1, 4999)))

    assert entry(snapshot, 4999).status ==
             {:skipped, "Couldn't forward it: administratively prohibited"}
  end

  test "when the tunnel closes, its forwards are gone, and it opens again", %{agent: agent} do
    FakeTunnel.set(agent, :ss, FakeTunnel.ss([{"127.0.0.1", 4000, "beam.smp"}]))
    pid = start(agent)
    assert_receive {:tunnel, :open, ref, _opts}
    report(&(&1.status == :on))

    send(pid, {ref, {:data, "client_loop: send disconnect: Broken pipe\n"}})
    send(pid, {ref, {:exit_status, 255}})

    assert %{ports: []} =
             report(
               &(&1.status ==
                   {:error,
                    "The connection to the VM closed (client_loop: send disconnect: Broken pipe)"})
             )

    assert_receive {:tunnel, :open, new_ref, _opts}
    assert new_ref != ref
    report(&(&1.status == :on and entry(&1, 4000).status == :forwarded))
  end

  test "a tunnel that can't open says why and keeps trying", %{agent: agent} do
    FakeTunnel.set(agent, :open, {:error, "msb isn't installed"})
    start(agent)

    report(&(&1.status == {:error, "msb isn't installed"}))
    assert_receive {:tunnel, :open_failed}
    assert_receive {:tunnel, :open_failed}

    FakeTunnel.set(agent, :open, :ok)
    assert_receive {:tunnel, :open, _ref, _opts}
    report(&(&1.status == :on))
  end

  test "listings that fail while the tunnel comes up wait a little before they show", %{
    agent: agent
  } do
    FakeTunnel.set(agent, :ss, {:error, "Control socket connect: No such file"})
    start(agent)

    refute_receive {:ports, _, %{status: {:error, _}}}, 120

    report(
      &(&1.status ==
          {:error, "Couldn't list the VM's ports: Control socket connect: No such file"})
    )
  end

  test "stopping closes the tunnel", %{agent: agent} do
    start(agent)
    assert_receive {:tunnel, :open, ref, _opts}
    report(&(&1.status == :on))

    stop_supervised!(Forwarder)
    assert_receive {:tunnel, :close, ^ref}
  end
end
