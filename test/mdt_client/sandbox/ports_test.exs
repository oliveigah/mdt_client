defmodule MDTClient.Sandbox.PortsTest do
  use ExUnit.Case, async: true

  alias MDTClient.Sandbox.{Forwarder, HostInfo, Ports}

  test "each identity's VM has a fixed loopback address of its own" do
    ids = for n <- 1..200, do: Base.encode16(:crypto.hash(:sha256, "identity-#{n}"), case: :lower)
    addresses = Enum.map(ids, &Ports.address/1)

    assert Ports.address(hd(ids)) == hd(addresses)
    assert length(Enum.uniq(addresses)) > 190

    for address <- addresses do
      assert ["127", "77", x, y] = String.split(address, ".")
      assert String.to_integer(x) in 0..255
      assert String.to_integer(y) in 1..254
    end

    assert Ports.url("127.77.1.2", 4000) == "http://127.77.1.2:4000"
  end

  test "reads ss: one listener per port, every address it listens on, the process" do
    output = """
    LISTEN 0      4096       127.0.0.1:4000       0.0.0.0:*    users:(("beam.smp",pid=12,fd=20))
    LISTEN 0      511          0.0.0.0:5173       0.0.0.0:*    users:(("node",pid=13,fd=21))
    LISTEN 0      4096           [::1]:8080          [::]:*    users:(("python3",pid=14,fd=3))
    LISTEN 0      4096               *:9000             *:*    users:(("caddy",pid=15,fd=7))
    LISTEN 0      4096   127.0.0.53%lo:53         0.0.0.0:*
    LISTEN 0      4096 [::ffff:127.0.0.1]:7000          *:*
    LISTEN 0      4096            [::]:4000          [::]:*    users:(("beam.smp",pid=12,fd=21))
    State  Recv-Q Send-Q Local Address:Port Peer Address:Port Process
    not a line ss prints
    """

    assert Ports.parse(output) == [
             %{port: 53, binds: ["127.0.0.53"], process: nil},
             %{port: 4000, binds: ["127.0.0.1", "::"], process: "beam.smp"},
             %{port: 5173, binds: ["0.0.0.0"], process: "node"},
             %{port: 7000, binds: ["127.0.0.1"], process: nil},
             %{port: 8080, binds: ["::1"], process: "python3"},
             %{port: 9000, binds: ["*"], process: "caddy"}
           ]

    assert Ports.parse("") == []
  end

  test "forwards each port to loopback inside the VM when it can, and says why not" do
    listeners = [
      %{port: 80, binds: ["0.0.0.0"], process: "nginx"},
      %{port: 3000, binds: ["10.0.2.15"], process: "app"},
      %{port: 3001, binds: ["127.0.0.2"], process: nil},
      %{port: 4000, binds: ["127.0.0.1", "::"], process: "beam.smp"},
      %{port: 8080, binds: ["::1"], process: "python3"},
      %{port: 9000, binds: ["*"], process: "caddy"},
      %{port: 9001, binds: ["::"], process: "v6only"}
    ]

    assert [
             %{port: 80, status: {:skipped, "Below 1024: listening on it here needs root"}},
             %{port: 3000, target: "10.0.2.15", status: :pending},
             %{port: 3001, target: "127.0.0.2", status: :pending},
             %{port: 4000, target: "127.0.0.1", status: :pending, process: "beam.smp"},
             %{port: 8080, target: "::1", status: :pending},
             %{port: 9000, target: "127.0.0.1", status: :pending},
             %{port: 9001, target: "::1", status: :pending}
           ] = Ports.plan(listeners, unprivileged_start: 1024)

    # A machine that lets anyone listen on any port forwards 80 too.
    assert [%{port: 80, status: :pending} | _] = Ports.plan(listeners, unprivileged_start: 0)

    # Skipped ports don't count toward the limit.
    assert [
             _,
             %{status: :pending},
             %{status: :pending},
             %{port: 4000, status: {:skipped, "Past 2 ports"}} | _
           ] =
             Ports.plan(listeners, unprivileged_start: 1024, max_ports: 2)
  end

  test "the tunnel's -L spec puts IPv6 targets in brackets" do
    assert Forwarder.SSH.spec("127.77.1.2", 4000, "127.0.0.1") == "127.77.1.2:4000:127.0.0.1:4000"
    assert Forwarder.SSH.spec("127.77.1.2", 8080, "::1") == "127.77.1.2:8080:[::1]:8080"
  end

  test "the tunnel ignores ~/.ssh/config, never prompts, and goes through msb ssh serve" do
    args = Forwarder.SSH.master_args("mdt-abc", "/opt/my msb/msb", "/k/forward_key", "/run/ctl")

    assert ["-M", "-N", "-n", "-S", "/run/ctl", "-F", "/dev/null", "-i", "/k/forward_key" | _] =
             args

    assert "BatchMode=yes" in args
    assert "IdentitiesOnly=yes" in args
    assert List.last(args) == "root@mdt-abc"

    # ssh runs ProxyCommand with `exec` itself.
    assert "ProxyCommand='/opt/my msb/msb' ssh serve 'mdt-abc' --stdio --no-inactivity-timeout" in args
  end

  test "agents read the address in the host's description" do
    facts = %{
      os: "Fedora",
      kernel: "Linux 7",
      arch: "x86_64",
      user: "me",
      home: "/home/me",
      shell: "/bin/bash"
    }

    text = HostInfo.text(facts, [], [], nil, "127.77.1.2")
    assert text =~ "## Servers you start"
    assert text =~ "http://127.77.1.2:PORT"
    assert text =~ "mdt ports"

    refute HostInfo.text(facts, [], [], nil) =~ "Servers you start"
  end
end
