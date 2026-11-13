# The one-day spike of step 5: intercepted hosts served by Bandit and a Plug,
# and sent on with Finch, in place of MDT's own reader.
#
#     MIX_ENV=test mix run --no-start test/review/http_spike/spike.exs
#
# It answers four things with what it measures:
#   1. the corpus of malformed and ambiguous requests: what Bandit refuses,
#      and what reaches the host for those it takes;
#   2. a request held for a long time before it is sent on (an approval);
#   3. a WebSocket upgrade;
#   4. time per request, with a new upstream connection each time (as MDT
#      does today) and with Finch's kept ones.
{:ok, _} = Application.ensure_all_started(:bandit)
{:ok, _} = Application.ensure_all_started(:finch)
{:ok, _} = Application.ensure_all_started(:ssl)
Logger.configure(level: :error)

alias MDTClient.Sandbox.CertificateAuthority, as: CA

defmodule Spike.Upstream do
  # A TLS host that answers each request with what it received.
  def start do
    leaf = CA.leaf(CA.new(), "localhost")

    options =
      CA.ssl_options(leaf) ++ [active: false, mode: :binary, reuseaddr: true, nodelay: true]

    {:ok, listen} = :ssl.listen(0, options ++ [alpn_preferred_protocols: ["http/1.1"]])
    {:ok, {_, port}} = :ssl.sockname(listen)
    spawn(fn -> accept(listen) end)
    port
  end

  defp accept(listen) do
    {:ok, socket} = :ssl.transport_accept(listen)

    spawn(fn ->
      case :ssl.handshake(socket, 5_000) do
        {:ok, socket} -> serve(socket)
        _ -> :ok
      end
    end)

    accept(listen)
  end

  # Keep-alive: one request, one answer, again.
  defp serve(socket) do
    case read_request(socket, "") do
      {:ok, request} ->
        :persistent_term.put({:received, self()}, request)
        send(:spike, {:received, request})
        body = "RECEIVED:\n" <> request

        :ssl.send(
          socket,
          "HTTP/1.1 200 OK\r\ncontent-length: #{byte_size(body)}\r\n\r\n#{body}"
        )

        serve(socket)

      :closed ->
        :ssl.close(socket)
    end
  end

  defp read_request(socket, acc) do
    case :binary.split(acc, "\r\n\r\n") do
      [head, rest] ->
        length =
          case Regex.run(~r/content-length: (\d+)/i, head) do
            [_, n] -> String.to_integer(n)
            nil -> 0
          end

        chunked? = head =~ ~r/transfer-encoding: chunked/i
        {:ok, head <> "\r\n\r\n" <> body(socket, rest, length, chunked?)}

      [_] ->
        case :ssl.recv(socket, 0, 30_000) do
          {:ok, data} -> read_request(socket, acc <> data)
          _ -> :closed
        end
    end
  end

  defp body(socket, rest, _length, true) do
    if String.ends_with?(rest, "0\r\n\r\n") do
      rest
    else
      case :ssl.recv(socket, 0, 2_000) do
        {:ok, data} -> body(socket, rest <> data, 0, true)
        _ -> rest
      end
    end
  end

  defp body(_socket, rest, length, false) when byte_size(rest) >= length, do: rest

  defp body(socket, rest, length, false) do
    case :ssl.recv(socket, 0, 2_000) do
      {:ok, data} -> body(socket, rest <> data, length, false)
      _ -> rest
    end
  end
end

defmodule Spike.Proxy do
  # What MDT's part would be: read the request Bandit parsed, decide, send
  # it on with Finch, stream the answer back.
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, opts) do
    if hold = :persistent_term.get(:spike_hold, nil), do: Process.sleep(hold)

    cond do
      get_req_header(conn, "upgrade") != [] ->
        send(:spike, {:upgrade, conn.method, get_req_header(conn, "upgrade")})
        send_resp(conn, 501, "upgrade not passed on")

      true ->
        forward(conn, opts)
    end
  end

  defp forward(conn, opts) do
    query = if conn.query_string == "", do: "", else: "?" <> conn.query_string
    url = "https://localhost:#{opts[:upstream]}" <> conn.request_path <> query

    headers =
      Enum.reject(conn.req_headers, fn {name, _} ->
        name in ~w(host connection keep-alive transfer-encoding content-length expect)
      end)

    {:ok, body, conn} = read_whole(conn, "")
    request = Finch.build(conn.method, url, [{"host", conn.host} | headers], body)

    case Finch.request(request, Spike.Finch, receive_timeout: 30_000) do
      {:ok, response} -> send_resp(conn, response.status, response.body)
      {:error, error} -> send_resp(conn, 502, Exception.message(error))
    end
  end

  defp read_whole(conn, acc) do
    case read_body(conn, length: 1_000_000) do
      {:ok, data, conn} -> {:ok, acc <> data, conn}
      {:more, data, conn} -> read_whole(conn, acc <> data)
    end
  end
end

Process.register(self(), :spike)
upstream = Spike.Upstream.start()

{:ok, _} =
  Finch.start_link(
    name: Spike.Finch,
    pools: %{default: [size: 8, conn_opts: [transport_opts: [verify: :verify_none]]]}
  )

{:ok, bandit} =
  Bandit.start_link(
    plug: {Spike.Proxy, upstream: upstream},
    scheme: :http,
    ip: {127, 0, 0, 1},
    port: 0,
    startup_log: false
  )

{:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)

flush = fn flush ->
  receive do
    _ -> flush.(flush)
  after
    0 -> :ok
  end
end

send_raw = fn bytes, wait ->
  flush.(flush)
  {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
  :ok = :gen_tcp.send(socket, bytes)

  response =
    case :gen_tcp.recv(socket, 0, wait) do
      {:ok, data} -> data
      {:error, reason} -> "(#{reason})"
    end

  :gen_tcp.close(socket)

  received =
    (fn collect ->
       collect.(collect, [])
     end).(fn collect, acc ->
      receive do
        {:received, request} -> collect.(collect, acc ++ [request])
      after
        150 -> acc
      end
    end)

  {response, received}
end

status = fn
  "HTTP/1.1 " <> <<status::binary-size(3), _::binary>> -> status
  other -> String.slice(other, 0, 12)
end

IO.puts("\n1. The corpus, sent to Bandit as it is\n")
placeholder = "mdt_ghp_PLACEHOLDER"
entries = MDTClient.SandboxCorpus.entries(placeholder)

rows =
  for entry <- entries do
    # The corpus names api.github.com; any Host does for Bandit.
    {response, received} = send_raw.(entry.bytes, 1_500)
    {entry, status.(response), received}
  end

differ =
  for {entry, got, received} <- rows,
      match?({:refused, _}, entry.expect),
      received != [] do
    {entry, got, received}
  end

IO.puts(
  "   #{length(entries)} requests. MDT's reader refuses #{Enum.count(entries, &match?({:refused, _}, &1.expect))} of them."
)

IO.puts("   Of those, Bandit takes #{length(differ)} and the host receives a request:\n")

for {entry, got, received} <- differ do
  [first | _] = received
  [line | _] = String.split(first, "\r\n")
  IO.puts("   #{String.pad_trailing(entry.name, 52)} #{got}  #{length(received)}x  #{line}")
end

refused_by_both =
  Enum.count(rows, fn {entry, _got, received} ->
    match?({:refused, _}, entry.expect) and received == []
  end)

IO.puts("\n   Refused by both: #{refused_by_both}.")

broken =
  for {entry, got, received} <- rows,
      entry.expect != {:refused, 0},
      not match?({:refused, _}, entry.expect),
      received == [] do
    "#{entry.name} (#{got})"
  end

IO.puts("   Ordinary requests Bandit or this Plug did not pass: #{inspect(broken)}")

IO.puts("\n2. A request held before it is sent on\n")

for seconds <- [5, 70] do
  :persistent_term.put(:spike_hold, seconds * 1_000)
  started = System.monotonic_time(:millisecond)

  {response, received} =
    send_raw.(
      "POST /held HTTP/1.1\r\nHost: localhost\r\nContent-Length: 5\r\n\r\nhello",
      (seconds + 20) * 1_000
    )

  took = System.monotonic_time(:millisecond) - started

  IO.puts(
    "   held #{seconds} s: #{status.(response)} after #{Float.round(took / 1000, 1)} s, the host received #{length(received)} request(s)"
  )
end

:persistent_term.put(:spike_hold, nil)

IO.puts("\n3. A WebSocket upgrade\n")

{response, _} =
  send_raw.(
    "GET /socket HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" <>
      "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n",
    2_000
  )

IO.puts(
  "   Bandit hands it to the Plug as an ordinary GET; this one answered #{status.(response)}."
)

IO.puts("   To pass it on, the Plug must take the socket over itself (WebSock) and speak")
IO.puts("   WebSocket frames to the host with a client of its own; there is none in the deps.")

IO.puts("\n4. Time per request\n")

kept = fn count ->
  {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, nodelay: true])

  {micro, :ok} =
    :timer.tc(fn ->
      for _ <- 1..count do
        :ok = :gen_tcp.send(socket, "GET /user HTTP/1.1\r\nHost: localhost\r\n\r\n")
        {:ok, _} = :gen_tcp.recv(socket, 0, 5_000)
      end

      :ok
    end)

  :gen_tcp.close(socket)
  micro / count / 1000
end

fresh = fn count ->
  {micro, :ok} =
    :timer.tc(fn ->
      for _ <- 1..count do
        {:ok, tls} =
          :ssl.connect(
            ~c"127.0.0.1",
            upstream,
            [verify: :verify_none, active: false, mode: :binary, nodelay: true],
            5_000
          )

        :ok = :ssl.send(tls, "GET /user HTTP/1.1\r\nhost: localhost\r\nconnection: close\r\n\r\n")
        {:ok, _} = :ssl.recv(tls, 0, 5_000)
        :ssl.close(tls)
      end

      :ok
    end)

  micro / count / 1000
end

kept.(50)

IO.puts(
  "   Through Bandit and Finch, connections kept on both sides: #{Float.round(kept.(500), 2)} ms"
)

IO.puts(
  "   A new TLS connection to the host for each request, as MDT makes today (loopback): #{Float.round(fresh.(200), 2)} ms"
)

IO.puts("")
