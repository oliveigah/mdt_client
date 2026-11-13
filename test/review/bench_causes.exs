# Isolates why a request through the interceptor costs what it does: the
# upstream socket's options, the CA list passed per connection, and bodies
# sent chunked.
#
#   MIX_ENV=test mix run test/review/bench_causes.exs
alias MDTClient.Accounts
alias MDTClient.Sandbox
alias MDTClient.Sandbox.CertificateAuthority, as: CA
alias MDTClient.Sandbox.Egress.Connection
alias MDTClient.Vault.Store

defmodule Review.Upstream2 do
  def start(ca) do
    leaf = CA.leaf(ca, "upstream.test")

    {:ok, listen} =
      :ssl.listen(
        0,
        CA.ssl_options(leaf) ++ [active: false, mode: :binary, reuseaddr: true, nodelay: true]
      )

    {:ok, {_, port}} = :ssl.sockname(listen)
    spawn_link(fn -> serve(listen) end)
    port
  end

  defp serve(listen) do
    {:ok, socket} = :ssl.transport_accept(listen)
    spawn(fn -> with {:ok, socket} <- :ssl.handshake(socket), do: answer(socket, "") end)
    serve(listen)
  end

  defp answer(socket, acc) do
    case :binary.split(acc, "\r\n\r\n") do
      [_head, _rest] ->
        :ssl.send(socket, "HTTP/1.1 200 OK\r\ncontent-length: 2\r\nconnection: close\r\n\r\nok")
        :ssl.close(socket)

      [_] ->
        case :ssl.recv(socket, 0, 30_000) do
          {:ok, data} -> answer(socket, acc <> data)
          {:error, _} -> :ssl.close(socket)
        end
    end
  end
end

defmodule Review.Client2 do
  def read(socket, acc \\ "") do
    case :binary.split(acc, "\r\n\r\n") do
      [_head, "ok" <> _] ->
        :ok

      _ ->
        case :ssl.recv(socket, 0, 10_000) do
          {:ok, data} -> read(socket, acc <> data)
          {:error, reason} -> {:error, reason, acc}
        end
    end
  end

  def request(proxy, ca, text) do
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

    :ok = :ssl.send(tls, text)
    :ok = read(tls)
    :ssl.close(tls)
  end
end

row = fn name, value, unit ->
  IO.puts(String.pad_trailing("  " <> name, 62) <> String.pad_leading(value, 10) <> " " <> unit)
end

username = "bench-#{System.unique_integer([:positive])}"
{:ok, profile, key} = Accounts.sign_in(username, "correct horse")
:ok = Store.open(profile.username, key)
username = profile.username

{:ok, grant} =
  Sandbox.create_grant(username, %{
    "kind" => "token",
    "name" => "GitHub",
    "purpose" => "The GitHub API",
    "hosts" => "api.github.com",
    "env" => "GH_TOKEN",
    "prefix" => "ghp_",
    "value" => "ghp_real_value"
  })

{:ok, grant} = Sandbox.turn_on(username, grant.id, :until_off, :all)
upstream_ca = CA.new()
upstream = Review.Upstream2.start(upstream_ca)
roots = [upstream_ca.cert | Enum.map(:public_key.cacerts_get(), fn {:cert, der, _} -> der end)]
[{:Certificate, ca, _}] = username |> Sandbox.ca_pem() |> :public_key.pem_decode()

proxy_with = fn extra, cacerts ->
  {:ok, listen} =
    :gen_tcp.listen(0, [
      :binary,
      active: false,
      ip: {127, 0, 0, 1},
      reuseaddr: true,
      backlog: 512,
      nodelay: true
    ])

  {:ok, port} = :inet.port(listen)

  options = [
    upstream: fn _host ->
      :ssl.connect(
        ~c"127.0.0.1",
        upstream,
        [
          verify: :verify_peer,
          cacerts: cacerts,
          server_name_indication: ~c"upstream.test",
          active: false,
          mode: :binary
        ] ++ extra
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
  port
end

get =
  "GET /user HTTP/1.1\r\nHost: api.github.com\r\nAuthorization: token #{grant.placeholder}\r\n\r\n"

# The same roots as a file: ssl reads a `cacertfile` once and shares it
# between connections, where a `cacerts` list is taken in again per connect.
roots_file =
  Path.join(System.tmp_dir!(), "mdt-bench-roots-#{System.unique_integer([:positive])}.pem")

File.write!(
  roots_file,
  :public_key.pem_encode(Enum.map(roots, &{:Certificate, &1, :not_encrypted}))
)

file_proxy = fn ->
  {:ok, listen} =
    :gen_tcp.listen(0, [
      :binary,
      active: false,
      ip: {127, 0, 0, 1},
      reuseaddr: true,
      backlog: 512,
      nodelay: true
    ])

  {:ok, port} = :inet.port(listen)

  options = [
    upstream: fn _host ->
      :ssl.connect(~c"127.0.0.1", upstream,
        nodelay: true,
        verify: :verify_peer,
        cacertfile: roots_file,
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
  port
end

variants = [
  {"no nodelay, #{length(roots)} roots as a list", proxy_with.([], roots)},
  {"+ nodelay: true (Connection.upstream/1 now)", proxy_with.([nodelay: true], roots)},
  {"+ nodelay: true, the #{length(roots)} roots as a file", file_proxy.()},
  {"+ nodelay: true, 1 root as a list", proxy_with.([nodelay: true], [upstream_ca.cert])}
]

IO.puts("\nOne GET through the interceptor, local upstream (ms per request, 200 sequential)")

for {name, port} <- variants do
  for _ <- 1..10, do: Review.Client2.request(port, ca, get)
  {micro, _} = :timer.tc(fn -> for _ <- 1..200, do: Review.Client2.request(port, ca, get) end)
  row.(name, :erlang.float_to_binary(micro / 200 / 1000, decimals: 2), "ms")
end

IO.puts("\n64 at once, 1280 requests (requests/s)")

for {name, port} <- variants do
  started = System.monotonic_time(:millisecond)

  1..64
  |> Task.async_stream(fn _ -> for _ <- 1..20, do: Review.Client2.request(port, ca, get) end,
    max_concurrency: 64,
    timeout: :infinity
  )
  |> Stream.run()

  row.(
    name,
    "#{round(1280 / (System.monotonic_time(:millisecond) - started) * 1000)}",
    "requests/s"
  )
end

IO.puts(
  "\nA 27-byte JSON body, by how it is framed (ms per request, 5 each, fastest proxy above)"
)

{_, fast} = List.last(variants)
body = ~s({"title":"a small change"})

with_length =
  "POST /repos/o/r/issues HTTP/1.1\r\nHost: api.github.com\r\nAuthorization: token #{grant.placeholder}\r\n" <>
    "Content-Type: application/json\r\nContent-Length: #{byte_size(body)}\r\n\r\n" <> body

chunked =
  "POST /repos/o/r/issues HTTP/1.1\r\nHost: api.github.com\r\nAuthorization: token #{grant.placeholder}\r\n" <>
    "Content-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n" <>
    Integer.to_string(byte_size(body), 16) <> "\r\n" <> body <> "\r\n0\r\n\r\n"

for {name, text} <- [{"Content-Length", with_length}, {"Transfer-Encoding: chunked", chunked}] do
  {micro, _} = :timer.tc(fn -> for _ <- 1..5, do: Review.Client2.request(fast, ca, text) end)
  row.(name, :erlang.float_to_binary(micro / 5 / 1000, decimals: 1), "ms")
end

Store.close(username)
File.rm_rf!(Accounts.dir(username))
