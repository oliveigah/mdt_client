# Tunnel throughput and CPU: today's relay (Egress.Connection) against
# prototype relays, with the endpoints in Python so the BEAM's CPU time is
# the relay's alone.
#
#   MIX_ENV=test mix run test/review/bench_tunnel.exs
alias MDTClient.Accounts
alias MDTClient.Sandbox
alias MDTClient.Sandbox.Egress.Connection
alias MDTClient.Vault.Store

defmodule Review.Relay do
  @moduledoc "Prototype byte relays, to compare with Egress.Connection's splice."

  # Accepts on a port; each connection answers CONNECT, dials `target` and
  # relays with `variant`.
  def listen(variant, target) do
    {:ok, listen} =
      :gen_tcp.listen(
        0,
        [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true, nodelay: true] ++
          opts(variant)
      )

    {:ok, port} = :inet.port(listen)
    spawn_link(fn -> accept(listen, variant, target) end)
    port
  end

  defp opts(:once_default), do: []
  defp opts(_other), do: [buffer: 262_144]

  defp accept(listen, variant, target) do
    {:ok, client} = :gen_tcp.accept(listen)

    pid =
      spawn(fn ->
        receive do
          :go -> serve(client, variant, target)
        end
      end)

    :gen_tcp.controlling_process(client, pid)
    send(pid, :go)
    accept(listen, variant, target)
  end

  defp serve(client, variant, target) do
    {:ok, head} = :gen_tcp.recv(client, 0, 5_000)
    true = String.starts_with?(head, "CONNECT ")
    :ok = :gen_tcp.send(client, "HTTP/1.1 200 Connection Established\r\n\r\n")

    {:ok, upstream} =
      :gen_tcp.connect(
        {127, 0, 0, 1},
        target,
        [:binary, active: false, nodelay: true] ++ opts(variant)
      )

    relay(variant, client, upstream)
  end

  # Today's shape: one process, one message per read, re-armed each time.
  defp relay(variant, a, b) when variant in [:once_default, :once_big] do
    :inet.setopts(a, active: :once)
    :inet.setopts(b, active: :once)
    once(a, b)
  end

  # One process, the socket re-armed every 64 reads.
  defp relay(:active_n, a, b) do
    :inet.setopts(a, active: 64)
    :inet.setopts(b, active: 64)
    counted(a, b)
  end

  # One process per direction, blocking recv then send: no messages, and
  # the kernel's own backpressure.
  defp relay(:passive, a, b) do
    parent = self()
    up = spawn_link(fn -> pump(a, b, parent) end)
    down = spawn_link(fn -> pump(b, a, parent) end)

    receive do
      {:done, _} -> :ok
    end

    :gen_tcp.close(a)
    :gen_tcp.close(b)
    Process.unlink(up)
    Process.unlink(down)
    Process.exit(up, :kill)
    Process.exit(down, :kill)
  end

  defp once(a, b) do
    receive do
      {:tcp, ^a, data} ->
        :gen_tcp.send(b, data)
        :inet.setopts(a, active: :once)
        once(a, b)

      {:tcp, ^b, data} ->
        :gen_tcp.send(a, data)
        :inet.setopts(b, active: :once)
        once(a, b)

      {:tcp_closed, _} ->
        :gen_tcp.close(a)
        :gen_tcp.close(b)
    end
  end

  defp counted(a, b) do
    receive do
      {:tcp, ^a, data} ->
        :gen_tcp.send(b, data)
        counted(a, b)

      {:tcp, ^b, data} ->
        :gen_tcp.send(a, data)
        counted(a, b)

      {:tcp_passive, socket} ->
        :inet.setopts(socket, active: 64)
        counted(a, b)

      {:tcp_closed, _} ->
        :gen_tcp.close(a)
        :gen_tcp.close(b)
    end
  end

  defp pump(from, to, parent) do
    case :gen_tcp.recv(from, 0) do
      {:ok, data} ->
        case :gen_tcp.send(to, data) do
          :ok -> pump(from, to, parent)
          _ -> send(parent, {:done, self()})
        end

      {:error, _} ->
        send(parent, {:done, self()})
    end
  end
end

py = Path.join(__DIR__, "endpoints.py")

free_port = fn ->
  {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
  {:ok, port} = :inet.port(socket)
  :gen_tcp.close(socket)
  port
end

start_python = fn mode, port ->
  port_handle =
    Port.open({:spawn_executable, System.find_executable("python3")}, [
      :binary,
      :exit_status,
      args: [py, mode, "#{port}"]
    ])

  receive do
    {^port_handle, {:data, "ready" <> _}} -> port_handle
  after
    5_000 -> raise "python #{mode} did not start"
  end
end

source = free_port.()
start_python.("serve", source)
banner = free_port.()
start_python.("serve_first", banner)

# An unlocked identity whose proxy may reach the two local servers.
username = "bench-#{System.unique_integer([:positive])}"
{:ok, profile, key} = Accounts.sign_in(username, "correct horse")
:ok = Store.open(profile.username, key)
username = profile.username

{:ok, grant} =
  Sandbox.create_grant(username, %{
    "kind" => "network",
    "name" => "Bench",
    "purpose" => "The benchmark's servers",
    "destinations" => "127.0.0.1:#{source}\n127.0.0.1:#{banner}"
  })

{:ok, _} = Sandbox.turn_on(username, grant.id, :until_off, :all)

{:ok, listen} =
  :gen_tcp.listen(0, [
    :binary,
    active: false,
    ip: {127, 0, 0, 1},
    reuseaddr: true,
    backlog: 512,
    nodelay: true
  ])

{:ok, mdt_port} = :inet.port(listen)

accept = fn accept ->
  {:ok, client} = :gen_tcp.accept(listen)

  pid =
    spawn(fn ->
      receive do
        :go -> Connection.run(client, username, [])
      end
    end)

  :gen_tcp.controlling_process(client, pid)
  send(pid, :go)
  accept.(accept)
end

spawn_link(fn -> accept.(accept) end)

{:ok, probe} = :gen_tcp.connect({127, 0, 0, 1}, source, [:binary, active: false])
{:ok, sizes} = :inet.getopts(probe, [:buffer, :recbuf, :sndbuf])
:gen_tcp.close(probe)
IO.puts("gen_tcp defaults on this machine: #{inspect(sizes)}")
IO.puts("monotonic clock: #{inspect(:erlang.system_info(:os_monotonic_time_source)[:clock_id])}")

gib = 1024 * 1024 * 1024
bytes = String.to_integer(System.get_env("GIB", "1")) * gib

fetch = fn port, target ->
  args = [py, "fetch", "#{port}", "#{bytes}"] ++ if(target, do: [target], else: [])
  {cpu_before, _} = :erlang.statistics(:runtime)
  {out, 0} = System.cmd("python3", args)
  {cpu_after, _} = :erlang.statistics(:runtime)
  [seconds, got] = String.split(out)
  {String.to_float(seconds), String.to_integer(got), cpu_after - cpu_before}
end

target = "127.0.0.1:#{source}"

runs = [
  {"direct, no proxy", fn -> fetch.(source, nil) end},
  {"MDT today (Egress.Connection)", fn -> fetch.(mdt_port, target) end},
  {"proto: active once, default buffer",
   fn -> fetch.(Review.Relay.listen(:once_default, source), target) end},
  {"proto: active once, 256 KiB buffer",
   fn -> fetch.(Review.Relay.listen(:once_big, source), target) end},
  {"proto: active 64, 256 KiB buffer",
   fn -> fetch.(Review.Relay.listen(:active_n, source), target) end},
  {"proto: 2 procs, passive recv/send",
   fn -> fetch.(Review.Relay.listen(:passive, source), target) end}
]

IO.puts("\n1 GiB download through a tunnel on loopback, best of 2")
IO.puts(String.pad_trailing("relay", 40) <> "  MiB/s   BEAM CPU ms per GiB")

for {name, run} <- runs do
  results =
    for _ <- 1..2,
        do:
          (
            r = run.()
            IO.write(:stderr, "  #{name}: #{inspect(r)}\n")
            r
          )

  {seconds, got, cpu} = Enum.min_by(results, &elem(&1, 0))
  ^bytes = got

  IO.puts(
    String.pad_trailing(name, 40) <>
      String.pad_leading("#{round(bytes / 1024 / 1024 / seconds)}", 7) <>
      String.pad_leading("#{round(cpu / (bytes / gib))}", 12)
  )
end

# A server that speaks first (SSH, SMTP, MySQL): time to its first byte.
first_byte = fn port, target ->
  args = [py, "banner", "#{port}"] ++ if(target, do: [target], else: [])
  {out, 0} = System.cmd("python3", args)
  out |> String.trim() |> String.to_float()
end

IO.puts("\nserver-speaks-first, time to first byte (s)")
IO.puts("  direct:    #{first_byte.(banner, nil)}")
IO.puts("  MDT today: #{first_byte.(mdt_port, "127.0.0.1:#{banner}")}")

Store.close(username)
File.rm_rf!(Accounts.dir(username))
