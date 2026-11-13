defmodule MDTClient.Sandbox.EgressTest do
  @moduledoc """
  The proxy end to end, over real TCP and TLS: a client speaking to it the
  way microsandbox does (CONNECT, then TLS that trusts only the sandbox CA),
  and an upstream that echoes what it was sent.
  """
  use ExUnit.Case, async: true

  alias MDTClient.Sandbox
  alias MDTClient.Sandbox.CertificateAuthority, as: CA
  alias MDTClient.Sandbox.Egress.Connection

  setup do
    %{username: username} = MDTClient.VaultHelpers.unlocked_identity("egress")
    upstream = start_upstream()

    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listen)

    options = [
      upstream: fn _host ->
        :ssl.connect(~c"127.0.0.1", upstream, verify: :verify_none, active: false, mode: :binary)
      end
    ]

    spawn_link(fn -> accept(listen, username, options) end)

    [{:Certificate, ca, _}] = username |> Sandbox.ca_pem() |> :public_key.pem_decode()
    %{username: username, proxy: port, ca: ca}
  end

  defp accept(listen, username, options) do
    {:ok, client} = :gen_tcp.accept(listen)

    pid =
      spawn(fn ->
        receive do
          :go -> Connection.run(client, username, options)
        end
      end)

    :gen_tcp.controlling_process(client, pid)
    send(pid, :go)
    accept(listen, username, options)
  end

  # Answers each request with what it received: the authorization header in
  # a response header and in the body.
  defp start_upstream do
    leaf = CA.leaf(CA.new(), "upstream.test")

    {:ok, listen} =
      :ssl.listen(0, CA.ssl_options(leaf) ++ [active: false, mode: :binary, reuseaddr: true])

    {:ok, {_, port}} = :ssl.sockname(listen)

    spawn_link(fn -> serve(listen) end)
    port
  end

  defp serve(listen) do
    {:ok, socket} = :ssl.transport_accept(listen)

    spawn(fn ->
      {:ok, socket} = :ssl.handshake(socket)
      head = read_until(socket, "\r\n\r\n", "")
      [_, auth] = Regex.run(~r/authorization: ([^\r]*)/i, head) || [nil, "none"]
      body = "seen=" <> auth

      :ssl.send(
        socket,
        "HTTP/1.1 200 OK\r\nx-echo: #{auth}\r\ncontent-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n#{body}"
      )

      :ssl.close(socket)
    end)

    serve(listen)
  end

  defp read_until(socket, marker, acc) do
    if String.contains?(acc, marker) do
      acc
    else
      {:ok, data} = :ssl.recv(socket, 0, 5_000)
      read_until(socket, marker, acc <> data)
    end
  end

  defp read_all(socket, mod, acc \\ "") do
    case mod.recv(socket, 0, 5_000) do
      {:ok, data} -> read_all(socket, mod, acc <> data)
      {:error, _closed} -> acc
    end
  end

  defp connect(proxy, target) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", proxy, [:binary, active: false])
    :ok = :gen_tcp.send(socket, "CONNECT #{target} HTTP/1.1\r\nHost: #{target}\r\n\r\n")
    {:ok, reply} = :gen_tcp.recv(socket, 0, 5_000)
    {socket, reply}
  end

  defp https(proxy, ca, host, request) do
    {socket, "HTTP/1.1 200" <> _} = connect(proxy, "140.82.112.3:443")

    {:ok, tls} =
      :ssl.connect(socket,
        verify: :verify_peer,
        cacerts: [ca],
        server_name_indication: String.to_charlist(host),
        alpn_advertised_protocols: ["h2", "http/1.1"],
        active: false,
        mode: :binary
      )

    assert {:ok, "http/1.1"} = :ssl.negotiated_protocol(tls)
    :ok = :ssl.send(tls, request)
    read_all(tls, :ssl)
  end

  defp github(username, uses \\ :all) do
    {:ok, grant} =
      Sandbox.create_grant(username, %{
        "kind" => "token",
        "preset" => "github",
        "name" => "GitHub",
        "purpose" => "The GitHub API",
        "hosts" => "api.github.com, github.com",
        "env" => "GH_TOKEN",
        "prefix" => "ghp_",
        "value" => "ghp_real_value"
      })

    {:ok, grant} = Sandbox.turn_on(username, grant.id, 60, uses)
    grant
  end

  test "a held request waits on the wire, and its approval carries it in full", %{
    username: username,
    proxy: proxy,
    ca: ca
  } do
    grant = github(username, :ask)
    body = ~s({"title":"Fix the stall","head":"fix"})

    sent =
      Task.async(fn ->
        https(
          proxy,
          ca,
          "api.github.com",
          "POST /repos/o/r/pulls HTTP/1.1\r\nHost: api.github.com\r\n" <>
            "Authorization: token #{grant.placeholder}\r\nContent-Type: application/json\r\n" <>
            "Content-Length: #{byte_size(body)}\r\n\r\n" <> body
        )
      end)

    approval =
      Enum.find_value(1..200, fn _ ->
        case Sandbox.snapshot(username).waiting do
          [approval] -> approval
          [] -> Process.sleep(10) && nil
        end
      end)

    assert approval.request.method == "POST"
    assert approval.request.body == body
    assert {"authorization", "token #{grant.placeholder}"} in approval.request.headers
    assert {"Title", "Fix the stall"} in approval.claims

    :ok = Sandbox.decide(username, approval.id, :allow_once)
    response = Task.await(sent)
    assert response =~ "HTTP/1.1 200 OK"
    assert response =~ "seen=token ghp_real_value"
  end

  test "a read request leaves with the real value, which never comes back", %{
    username: username,
    proxy: proxy,
    ca: ca
  } do
    grant = github(username)

    response =
      https(
        proxy,
        ca,
        "api.github.com",
        "GET /user HTTP/1.1\r\nHost: api.github.com\r\nAuthorization: token #{grant.placeholder}\r\n\r\n"
      )

    assert response =~ "HTTP/1.1 200 OK"
    assert response =~ "seen=token ghp_real_value"
    assert response =~ "x-echo: token #{grant.placeholder}"
    refute response =~ "x-echo: token ghp_real_value"
  end

  test "an off grant is refused with JSON the agent can read", %{
    username: username,
    proxy: proxy,
    ca: ca
  } do
    grant = github(username)
    {:ok, _} = Sandbox.turn_off(username, grant.id)

    response =
      https(
        proxy,
        ca,
        "api.github.com",
        "GET /user HTTP/1.1\r\nHost: api.github.com\r\nAuthorization: token #{grant.placeholder}\r\n\r\n"
      )

    assert response =~ "HTTP/1.1 403 Forbidden"
    assert response =~ ~s("code":"mdt_grant_off")
    refute response =~ "seen="
  end

  test "a request for another host than it was encrypted for is refused", %{
    username: username,
    proxy: proxy,
    ca: ca
  } do
    github(username)

    response = https(proxy, ca, "api.github.com", "GET / HTTP/1.1\r\nHost: evil.example\r\n\r\n")
    assert response =~ "HTTP/1.1 421"
  end

  test "hosts no grant names are tunnelled unread; refused ones are not reached", %{
    username: username,
    proxy: proxy
  } do
    {:ok, echo} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, echo_port} = :inet.port(echo)

    spawn_link(fn ->
      {:ok, socket} = :gen_tcp.accept(echo)
      {:ok, data} = :gen_tcp.recv(socket, 0, 5_000)
      :gen_tcp.send(socket, "pong:" <> data)
      :gen_tcp.close(socket)
    end)

    {socket, reply} = connect(proxy, "127.0.0.1:#{echo_port}")
    assert reply =~ "403"
    :gen_tcp.close(socket)

    {:ok, tunnel} =
      Sandbox.create_grant(username, %{
        "kind" => "network",
        "name" => "Tunnel",
        "purpose" => "The echo server",
        "destinations" => "127.0.0.1:#{echo_port}"
      })

    {:ok, _} = Sandbox.turn_on(username, tunnel.id, 60, :all)

    {socket, "HTTP/1.1 200" <> _} = connect(proxy, "127.0.0.1:#{echo_port}")
    :ok = :gen_tcp.send(socket, "ping")
    assert read_all(socket, :gen_tcp) == "pong:ping"

    Enum.find_value(1..100, fn _ ->
      Enum.find(Sandbox.events(username), &(&1.outcome == :tunnel)) || (Process.sleep(10) && nil)
    end)

    assert %{up: 4, down: 9} = Enum.find(Sandbox.events(username), &(&1.outcome == :tunnel))
  end

  # A proxy with other options than the one `setup` starts.
  defp proxy_with(username, options) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listen)
    spawn_link(fn -> accept(listen, username, options) end)
    port
  end

  # A server on this machine, and the network grant that reaches it.
  defp local_server(username, uses) do
    {:ok, server} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(server)

    {:ok, grant} =
      Sandbox.create_grant(username, %{
        "kind" => "network",
        "name" => "Local #{port}",
        "purpose" => "A test server",
        "destinations" => "127.0.0.1:#{port}"
      })

    {:ok, _} = Sandbox.turn_on(username, grant.id, 60, uses)
    {server, port}
  end

  test "a connection waiting for you is answered before microsandbox gives up; a no closes it",
       %{username: username} do
    {server, port} = local_server(username, :ask)
    proxy = proxy_with(username, answer_within: 50)

    {socket, reply} = connect(proxy, "127.0.0.1:#{port}")
    assert reply =~ "HTTP/1.1 200"
    assert [approval] = Sandbox.snapshot(username).waiting
    # Nothing has reached the destination.
    assert {:error, :timeout} = :gen_tcp.accept(server, 50)

    :ok = Sandbox.decide(username, approval.id, :deny)
    assert {:error, :closed} = :gen_tcp.recv(socket, 0, 5_000)
    assert {:error, :timeout} = :gen_tcp.accept(server, 50)
  end

  test "a connection waiting for you opens when you allow it", %{username: username} do
    {server, port} = local_server(username, :ask)
    proxy = proxy_with(username, answer_within: 50)

    spawn_link(fn ->
      {:ok, socket} = :gen_tcp.accept(server)
      {:ok, data} = :gen_tcp.recv(socket, 0, 5_000)
      :gen_tcp.send(socket, "pong:" <> data)
      :gen_tcp.close(socket)
    end)

    {socket, "HTTP/1.1 200" <> _} = connect(proxy, "127.0.0.1:#{port}")
    :ok = :gen_tcp.send(socket, "ping")
    assert [approval] = Sandbox.snapshot(username).waiting
    :ok = Sandbox.decide(username, approval.id, :allow_once)
    assert read_all(socket, :gen_tcp) == "pong:ping"
  end

  test "a server that speaks first is heard without the wait for the client", %{
    username: username,
    proxy: proxy
  } do
    {server, port} = local_server(username, :all)

    spawn_link(fn ->
      {:ok, socket} = :gen_tcp.accept(server)
      :gen_tcp.send(socket, "220 ready\r\n")
      :gen_tcp.recv(socket, 0, 5_000)
      :gen_tcp.close(socket)
    end)

    {socket, "HTTP/1.1 200" <> _} = connect(proxy, "127.0.0.1:#{port}")
    started = System.monotonic_time(:millisecond)
    assert {:ok, "220 ready\r\n"} = :gen_tcp.recv(socket, 0, 5_000)
    # It used to sit out 1.5 s waiting for the client to speak.
    assert System.monotonic_time(:millisecond) - started < 1_000
  end

  test "a request two parsers could read two ways is refused", %{
    username: username,
    proxy: proxy,
    ca: ca
  } do
    grant = github(username)
    start = "HTTP/1.1\r\nHost: api.github.com\r\nAuthorization: token #{grant.placeholder}\r\n"

    requests = [
      {"two ways of saying the length",
       "POST /x #{start}Content-Length: 4\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n"},
      {"two lengths", "POST /x #{start}Content-Length: 4\r\nContent-Length: 0\r\n\r\nabcd"},
      {"a length that isn't a number", "POST /x #{start}Content-Length: 4, 4\r\n\r\nabcd"},
      {"an encoding besides chunked",
       "POST /x #{start}Transfer-Encoding: gzip, chunked\r\n\r\n0\r\n\r\n"},
      {"a folded header", "GET /x #{start}X-A: 1\r\n folded\r\n\r\n"},
      {"a space before the colon",
       "GET /x HTTP/1.1\r\nHost : api.github.com\r\nAuthorization: token #{grant.placeholder}\r\n\r\n"},
      {"no Host", "GET /x HTTP/1.1\r\nAuthorization: token #{grant.placeholder}\r\n\r\n"},
      {"a line that isn't a header", "GET /x #{start}not a header\r\n\r\n"}
    ]

    for {why, request} <- requests do
      response = https(proxy, ca, "api.github.com", request)
      assert response =~ "HTTP/1.1 400", why
      assert response =~ "mdt_bad_request", why
      refute response =~ "ghp_real_value", why
    end
  end

  test "a small chunked body is not waited on", %{username: username, proxy: proxy, ca: ca} do
    grant = github(username)
    body = ~s({"title":"a small change"})

    request =
      "POST /repos/o/r/issues HTTP/1.1\r\nHost: api.github.com\r\n" <>
        "Authorization: token #{grant.placeholder}\r\nTransfer-Encoding: chunked\r\n\r\n" <>
        Integer.to_string(byte_size(body), 16) <> "\r\n" <> body <> "\r\n0\r\n\r\n"

    started = System.monotonic_time(:millisecond)
    assert https(proxy, ca, "api.github.com", request) =~ "seen=token ghp_real_value"
    # It used to wait 2 s for more of the body.
    assert System.monotonic_time(:millisecond) - started < 1_500
  end

  test "a chunked body is whole at its last chunk" do
    assert Connection.chunked_whole?("5\r\nhello\r\n0\r\n\r\n")
    assert Connection.chunked_whole?("5;ext=1\r\nhello\r\n0\r\nTrailer: x\r\n\r\n")
    refute Connection.chunked_whole?("5\r\nhello\r\n")
    refute Connection.chunked_whole?("5\r\nhel")
    refute Connection.chunked_whole?("5\r\nhello\r\n0\r\nTrailer: x\r\n")
    refute Connection.chunked_whole?("")
  end

  test "each unlocked identity's proxy listens on its own socket, and reports it", %{
    username: username
  } do
    proxy =
      Enum.find_value(1..100, fn _ ->
        case Sandbox.snapshot(username).proxy do
          %{listening?: true} = proxy -> proxy
          _ -> Process.sleep(10) && nil
        end
      end)

    assert proxy.path == MDTClient.Sandbox.Egress.path(username)
    # Yours only: no other user's program reaches the proxy, and none through a port.
    assert Bitwise.band(File.stat!(proxy.path).mode, 0o777) == 0o600
    assert Bitwise.band(File.stat!(Path.dirname(proxy.path)).mode, 0o777) == 0o700

    {:ok, socket} = :gen_tcp.connect({:local, proxy.path}, 0, [:binary, active: false])
    :ok = :gen_tcp.send(socket, "CONNECT 127.0.0.1:1 HTTP/1.1\r\n\r\n")
    assert {:ok, "HTTP/1.1 403" <> _} = :gen_tcp.recv(socket, 0, 5_000)
    :gen_tcp.close(socket)

    # A retry left over from a bind that failed must not report the proxy
    # down once it listens.
    egress = MDTClient.Vault.Store.whereis(MDTClient.Sandbox.Egress, username)
    send(egress, :listen)
    _ = :sys.get_state(egress)
    _ = :sys.get_state(MDTClient.Vault.Store.whereis(MDTClient.Sandbox.Server, username))
    assert %{listening?: true, error: nil} = Sandbox.snapshot(username).proxy
  end

  test "a request is read through the socket as through a port", %{username: username, ca: ca} do
    grant = github(username)
    path = MDTClient.Sandbox.Egress.path(username)

    Enum.find_value(1..100, fn _ ->
      Sandbox.snapshot(username).proxy.listening? || (Process.sleep(10) && nil)
    end)

    {:ok, socket} = :gen_tcp.connect({:local, path}, 0, [:binary, active: false])
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

    # TRACE is refused by MDT itself, so no upstream is needed to see that
    # the request was read.
    :ok =
      :ssl.send(
        tls,
        "TRACE /user HTTP/1.1\r\nHost: api.github.com\r\nAuthorization: token #{grant.placeholder}\r\n\r\n"
      )

    assert read_all(tls, :ssl) =~ "mdt_method_refused"
  end
end
