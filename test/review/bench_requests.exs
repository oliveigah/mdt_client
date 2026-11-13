# What a request on an intercepted host costs, and what the sandbox server's
# hot path costs per connection.
#
#   MIX_ENV=test mix run test/review/bench_requests.exs
alias MDTClient.Accounts
alias MDTClient.Sandbox
alias MDTClient.Sandbox.{Destinations, Inbox, Server}
alias MDTClient.Sandbox.CertificateAuthority, as: CA
alias MDTClient.Sandbox.Egress.Connection
alias MDTClient.Vault
alias MDTClient.Vault.Store

defmodule Review.Upstream do
  @moduledoc "A TLS server that answers every request on a connection, so keep-alive can be measured."

  def start(ca) do
    leaf = CA.leaf(ca, "upstream.test")

    {:ok, listen} =
      :ssl.listen(0, CA.ssl_options(leaf) ++ [active: false, mode: :binary, reuseaddr: true])

    {:ok, {_, port}} = :ssl.sockname(listen)
    spawn_link(fn -> serve(listen) end)
    port
  end

  defp serve(listen) do
    {:ok, socket} = :ssl.transport_accept(listen)

    spawn(fn ->
      with {:ok, socket} <- :ssl.handshake(socket), do: answer(socket, "")
    end)

    serve(listen)
  end

  defp answer(socket, acc) do
    case :binary.split(acc, "\r\n\r\n") do
      [head, rest] ->
        close? = head =~ ~r/connection: close/i

        :ssl.send(
          socket,
          "HTTP/1.1 200 OK\r\ncontent-length: 2\r\n" <>
            if(close?, do: "connection: close\r\n", else: "") <> "\r\nok"
        )

        if close?, do: :ssl.close(socket), else: answer(socket, rest)

      [_] ->
        case :ssl.recv(socket, 0, 30_000) do
          {:ok, data} -> answer(socket, acc <> data)
          {:error, _} -> :ssl.close(socket)
        end
    end
  end
end

defmodule Review.Client do
  def read_response(socket, mod, acc \\ "") do
    case :binary.split(acc, "\r\n\r\n") do
      [_head, "ok" <> _] ->
        :ok

      _ ->
        case mod.recv(socket, 0, 5_000) do
          {:ok, data} -> read_response(socket, mod, acc <> data)
          {:error, reason} -> {:error, reason, acc}
        end
    end
  end

  # One request the way a client in the VM makes it: CONNECT, TLS with the
  # sandbox CA, the request, the response.
  def through_proxy(proxy, ca, placeholder) do
    {:ok, socket} =
      :gen_tcp.connect({127, 0, 0, 1}, proxy, [:binary, active: false, nodelay: true])

    :ok = :gen_tcp.send(socket, "CONNECT 140.82.112.3:443 HTTP/1.1\r\n\r\n")
    {:ok, "HTTP/1.1 200" <> _} = :gen_tcp.recv(socket, 0, 5_000)

    {:ok, tls} =
      :ssl.connect(socket,
        verify: :verify_peer,
        cacerts: [ca],
        server_name_indication: ~c"api.github.com",
        active: false,
        mode: :binary
      )

    :ok =
      :ssl.send(
        tls,
        "GET /user HTTP/1.1\r\nHost: api.github.com\r\nAuthorization: token #{placeholder}\r\n\r\n"
      )

    :ok = read_response(tls, :ssl)
    :ssl.close(tls)
  end

  def direct(port, options) do
    {:ok, tls} = :ssl.connect(~c"127.0.0.1", port, options ++ [active: false, mode: :binary])
    :ok = :ssl.send(tls, "GET /user HTTP/1.1\r\nHost: upstream.test\r\nconnection: close\r\n\r\n")
    :ok = read_response(tls, :ssl)
    :ssl.close(tls)
  end
end

us = fn fun, count ->
  {micro, _} = :timer.tc(fn -> for _ <- 1..count, do: fun.() end)
  micro / count
end

row = fn name, value, unit ->
  IO.puts(String.pad_trailing("  " <> name, 62) <> String.pad_leading(value, 10) <> " " <> unit)
end

username = "bench-#{System.unique_integer([:positive])}"
{:ok, profile, key} = Accounts.sign_in(username, "correct horse")
:ok = Store.open(profile.username, key)
username = profile.username
pid = Store.whereis(Server, username)

{:ok, grant} =
  Sandbox.create_grant(username, %{
    "kind" => "token",
    "preset" => "github",
    "name" => "GitHub",
    "purpose" => "The GitHub API",
    "hosts" => "api.github.com, github.com, uploads.github.com",
    "env" => "GH_TOKEN",
    "git" => "true",
    "prefix" => "ghp_",
    "value" => "ghp_real_value"
  })

{:ok, grant} = Sandbox.turn_on(username, grant.id, :until_off, :all)

# Nine more grants, as a used sandbox has.
for i <- 1..9 do
  {:ok, _} =
    Sandbox.create_grant(username, %{
      "kind" => "token",
      "name" => "Service #{i}",
      "purpose" => "An API",
      "hosts" => "api#{i}.example.com",
      "env" => "SERVICE_#{i}_TOKEN",
      "value" => "value-#{i}"
    })
end

upstream_ca = CA.new()
upstream = Review.Upstream.start(upstream_ca)

{:ok, listen} =
  :gen_tcp.listen(0, [
    :binary,
    active: false,
    ip: {127, 0, 0, 1},
    reuseaddr: true,
    backlog: 512,
    nodelay: true
  ])

{:ok, proxy} = :inet.port(listen)

options = [
  upstream: fn _host ->
    :ssl.connect(~c"127.0.0.1", upstream,
      verify: :verify_peer,
      cacerts: [upstream_ca.cert],
      server_name_indication: ~c"upstream.test",
      active: false,
      mode: :binary
    )
  end
]

accept = fn accept ->
  {:ok, client} = :gen_tcp.accept(listen)

  handler =
    spawn(fn ->
      receive do
        :go -> Connection.run(client, username, options)
      end
    end)

  :gen_tcp.controlling_process(client, handler)
  send(handler, :go)
  accept.(accept)
end

spawn_link(fn -> accept.(accept) end)
[{:Certificate, ca, _}] = username |> Sandbox.ca_pem() |> :public_key.pem_decode()

verify_one = [
  verify: :verify_peer,
  cacerts: [upstream_ca.cert],
  server_name_indication: ~c"upstream.test"
]

system_roots = :public_key.cacerts_get()

verify_all = [
  verify: :verify_peer,
  cacerts: [upstream_ca.cert | Enum.map(system_roots, fn {:cert, der, _} -> der end)],
  server_name_indication: ~c"upstream.test"
]

# Warm up: code loading, the leaf certificate.
for _ <- 1..20, do: Review.Client.through_proxy(proxy, ca, grant.placeholder)
for _ <- 1..20, do: Review.Client.direct(upstream, verify_one)

IO.puts("\nA request on an intercepted host, local upstream, sequential (ms per request)")
n = 300
via = us.(fn -> Review.Client.through_proxy(proxy, ca, grant.placeholder) end, n) / 1000

row.(
  "through MDT today (2 TLS handshakes, 4 server calls)",
  :erlang.float_to_binary(via, decimals: 2),
  "ms"
)

new_conn = us.(fn -> Review.Client.direct(upstream, verify_one) end, n) / 1000

row.(
  "direct, new TLS connection each (1 handshake)",
  :erlang.float_to_binary(new_conn, decimals: 2),
  "ms"
)

{:ok, kept} = :ssl.connect(~c"127.0.0.1", upstream, verify_one ++ [active: false, mode: :binary])

keep =
  us.(
    fn ->
      :ok = :ssl.send(kept, "GET /user HTTP/1.1\r\nHost: upstream.test\r\n\r\n")
      :ok = Review.Client.read_response(kept, :ssl)
    end,
    n
  ) / 1000

row.(
  "direct, one kept-alive connection (no handshake)",
  :erlang.float_to_binary(keep, decimals: 3),
  "ms"
)

IO.puts("\nConcurrent requests through MDT (#{System.schedulers_online()} schedulers)")

for parallel <- [1, 16, 64] do
  total = 640
  started = System.monotonic_time(:millisecond)

  1..parallel
  |> Task.async_stream(
    fn _ ->
      for _ <- 1..div(total, parallel),
          do: Review.Client.through_proxy(proxy, ca, grant.placeholder)
    end,
    max_concurrency: parallel,
    timeout: :infinity
  )
  |> Stream.run()

  elapsed = System.monotonic_time(:millisecond) - started
  row.("#{parallel} at once", "#{round(total / elapsed * 1000)}", "requests/s")
end

IO.puts("\nUpstream TLS connect (what a reused connection would save)")

one =
  us.(
    fn ->
      {:ok, s} = :ssl.connect(~c"127.0.0.1", upstream, verify_one ++ [active: false])
      :ssl.close(s)
    end,
    200
  ) / 1000

all =
  us.(
    fn ->
      {:ok, s} = :ssl.connect(~c"127.0.0.1", upstream, verify_all ++ [active: false])
      :ssl.close(s)
    end,
    200
  ) / 1000

row.("local, cacerts: 1 certificate", :erlang.float_to_binary(one, decimals: 2), "ms")

row.(
  "local, cacerts: #{length(system_roots) + 1} (as Connection.upstream/1 passes)",
  :erlang.float_to_binary(all, decimals: 2),
  "ms"
)

real =
  for _ <- 1..5 do
    {micro, result} =
      :timer.tc(fn ->
        :ssl.connect(
          ~c"api.github.com",
          443,
          [
            verify: :verify_peer,
            cacerts: :public_key.cacerts_get(),
            server_name_indication: ~c"api.github.com",
            customize_hostname_check: [
              match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
            ],
            alpn_advertised_protocols: ["http/1.1"],
            depth: 10,
            active: false,
            mode: :binary
          ],
          15_000
        )
      end)

    case result do
      {:ok, socket} ->
        :ssl.close(socket)
        micro / 1000

      {:error, reason} ->
        IO.puts("  api.github.com: #{inspect(reason)}")
        nil
    end
  end
  |> Enum.reject(&is_nil/1)

if real != [] do
  row.(
    "api.github.com:443, DNS + TCP + TLS, median of #{length(real)}",
    :erlang.float_to_binary(Enum.at(Enum.sort(real), div(length(real), 2)), decimals: 1),
    "ms"
  )
end

IO.puts("\nThe sandbox server's answers (µs per call, one caller, 10 grants)")

request = %{
  host: "api.github.com",
  method: "GET",
  path: "/user",
  headers: [
    {"host", "api.github.com"},
    {"authorization", "token " <> grant.placeholder},
    {"user-agent", "bench"}
  ],
  body: ""
}

row.(
  "{:destination, public ip}",
  :erlang.float_to_binary(
    us.(fn -> Server.call(username, {:destination, {140, 82, 112, 3}, 443}) end, 5_000),
    decimals: 1
  ),
  "µs"
)

row.(
  "  of which Destinations.host_addresses/0 (getifaddrs)",
  :erlang.float_to_binary(us.(fn -> Destinations.host_addresses() end, 5_000), decimals: 1),
  "µs"
)

row.(
  "{:intercept?, host}",
  :erlang.float_to_binary(
    us.(fn -> Server.call(username, {:intercept?, "api.github.com"}) end, 5_000),
    decimals: 1
  ),
  "µs"
)

row.(
  "{:leaf, host}, cached",
  :erlang.float_to_binary(us.(fn -> Server.call(username, {:leaf, "api.github.com"}) end, 5_000),
    decimals: 1
  ),
  "µs"
)

row.(
  "{:leaf, host}, new host (key + signature)",
  :erlang.float_to_binary(
    us.(
      fn ->
        Server.call(username, {:leaf, "h#{System.unique_integer([:positive])}.github.com"})
      end,
      300
    ),
    decimals: 1
  ),
  "µs"
)

row.(
  "{:authorize, request}, allowed by an allowance",
  :erlang.float_to_binary(us.(fn -> Server.call(username, {:authorize, request}) end, 5_000),
    decimals: 1
  ),
  "µs"
)

row.(
  ":snapshot (each open sandbox page, at most every 150 ms)",
  :erlang.float_to_binary(us.(fn -> Server.call(username, :snapshot) end, 500), decimals: 1),
  "µs"
)

# What a page does with a snapshot is its own cost; this is the server's.
state = :sys.get_state(pid)

sealed = fn ->
  Vault.seal(state.key, %{
    version: 1,
    grants: state.grants,
    values: state.values,
    settings: state.settings,
    ca: state.ca,
    created_spec: state.created_spec,
    created_ref: state.created_ref,
    builds: state.builds,
    current: state.image.tag,
    snapshots: state.snapshots,
    memory: state.memory
  })
end

IO.puts("\nWork done inside the server process")

row.(
  "persist: seal the whole state (#{byte_size(sealed.())} bytes)",
  :erlang.float_to_binary(us.(sealed, 500), decimals: 1),
  "µs"
)

row.(
  "  + write and rename",
  :erlang.float_to_binary(
    us.(
      fn ->
        File.write!(state.path <> ".bench", sealed.())
        File.rename!(state.path <> ".bench", state.path <> ".bench2")
      end,
      200
    ),
    decimals: 1
  ),
  "µs"
)

inbox = Path.join(state.dir, "inbox")

row.(
  "Inbox.write (every grant on/off, allowance, expiry)",
  :erlang.float_to_binary(
    us.(fn -> Inbox.write(inbox, state.grants, state.values, CA.pem(state.ca.cert)) end, 50),
    decimals: 1
  ),
  "µs"
)

row.(
  "  of which the CA bundle (#{length(system_roots)} roots to PEM)",
  :erlang.float_to_binary(us.(fn -> Inbox.bundle(CA.pem(state.ca.cert)) end, 50), decimals: 1),
  "µs"
)

row.(
  "turn a grant off and on (two calls)",
  :erlang.float_to_binary(
    us.(
      fn ->
        Sandbox.turn_off(username, grant.id)
        Sandbox.turn_on(username, grant.id, :until_off, :all)
      end,
      50
    ),
    decimals: 1
  ),
  "µs"
)

# Each allowed request marks the grant used: a broadcast and a flush timer.
# Count the state writes during a burst.
:erlang.trace(pid, true, [:receive])
burst = 2_000
started = System.monotonic_time(:millisecond)
for _ <- 1..burst, do: Server.call(username, {:authorize, request})
elapsed = System.monotonic_time(:millisecond) - started
Process.sleep(400)
:erlang.trace(pid, false, [:receive])

flushes =
  Stream.repeatedly(fn ->
    receive do
      {:trace, ^pid, :receive, :flush} -> 1
      {:trace, ^pid, :receive, _} -> 0
    after
      0 -> nil
    end
  end)
  |> Enum.take_while(&(&1 != nil))
  |> Enum.sum()

row.(
  "state rewritten to disk during #{burst} allowed requests (#{elapsed} ms)",
  "#{flushes}",
  "times"
)

IO.puts("\nPrivate destinations: DNS inside the server process (µs per connection)")

network = fn name, destinations ->
  {:ok, g} =
    Sandbox.create_grant(username, %{
      "kind" => "network",
      "name" => name,
      "purpose" => "bench",
      "destinations" => destinations
    })

  {:ok, _} = Sandbox.turn_on(username, g.id, :until_off, :all)
  g
end

g1 = network.("Range", "10.20.0.0/16:5432")

row.(
  "grant lists a range only",
  :erlang.float_to_binary(
    us.(fn -> Server.call(username, {:destination, {10, 99, 0, 5}, 5432}) end, 300),
    decimals: 1
  ),
  "µs"
)

Sandbox.delete_grant(username, g1.id)

g2 = network.("Name", "github.com:5432")

row.(
  "grant lists a name that resolves (github.com)",
  :erlang.float_to_binary(
    us.(fn -> Server.call(username, {:destination, {10, 99, 0, 5}, 5432}) end, 300),
    decimals: 1
  ),
  "µs"
)

Sandbox.delete_grant(username, g2.id)

g3 = network.("Gone", "db.vpn-is-down.invalid:5432")

row.(
  "grant lists a name that doesn't (VPN down)",
  :erlang.float_to_binary(
    us.(fn -> Server.call(username, {:destination, {10, 99, 0, 5}, 5432}) end, 100),
    decimals: 1
  ),
  "µs"
)

# While those lookups run, everything else the server does waits behind them.
parent = self()

spawn(fn ->
  for _ <- 1..50, do: Server.call(username, {:destination, {10, 99, 0, 5}, 5432})
  send(parent, :flood_done)
end)

Process.sleep(5)
waits = for _ <- 1..20, do: us.(fn -> Server.call(username, :waiting_count) end, 1) / 1000

row.(
  ":waiting_count while 1 VM process retries a private address, max",
  :erlang.float_to_binary(Enum.max(waits), decimals: 2),
  "ms"
)

receive do
  :flood_done -> :ok
after
  60_000 -> :ok
end

Sandbox.delete_grant(username, g3.id)
Store.close(username)
File.rm_rf!(Accounts.dir(username))
