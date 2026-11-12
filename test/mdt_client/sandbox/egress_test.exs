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

  defp github(username) do
    {:ok, grant} =
      Sandbox.create_grant(username, %{
        "recipe" => "github",
        "name" => "GitHub",
        "value" => "ghp_real_value"
      })

    {:ok, grant} = Sandbox.turn_on(username, grant.id, 60)
    grant
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
        "recipe" => "database",
        "name" => "Tunnel",
        "destinations" => "127.0.0.1:#{echo_port}"
      })

    {:ok, _} = Sandbox.turn_on(username, tunnel.id, 60)
    {:ok, _} = Sandbox.set_per_connection(username, tunnel.id, :allow)

    {socket, "HTTP/1.1 200" <> _} = connect(proxy, "127.0.0.1:#{echo_port}")
    :ok = :gen_tcp.send(socket, "ping")
    assert read_all(socket, :gen_tcp) == "pong:ping"

    Enum.find_value(1..100, fn _ ->
      Enum.find(Sandbox.events(username), &(&1.outcome == :tunnel)) || (Process.sleep(10) && nil)
    end)

    assert %{up: 4, down: 9} = Enum.find(Sandbox.events(username), &(&1.outcome == :tunnel))
  end

  test "each unlocked identity's proxy listens and reports where", %{username: username} do
    proxy =
      Enum.find_value(1..100, fn _ ->
        case Sandbox.snapshot(username).proxy do
          %{listening?: true} = proxy -> proxy
          _ -> Process.sleep(10) && nil
        end
      end)

    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", proxy.port, [:binary, active: false])
    :ok = :gen_tcp.send(socket, "CONNECT 127.0.0.1:1 HTTP/1.1\r\n\r\n")
    assert {:ok, "HTTP/1.1 403" <> _} = :gen_tcp.recv(socket, 0, 5_000)

    # A retry left over from a port that was busy must not report the proxy
    # down once it listens on a fixed port.
    :gen_tcp.close(socket)
    {:ok, _} = Sandbox.update_settings(username, %{"proxy_port" => "#{proxy.port}"})
    egress = MDTClient.Vault.Store.whereis(MDTClient.Sandbox.Egress, username)
    # The rebind, then the :listen it sends itself, then the report.
    _ = :sys.get_state(egress)
    _ = :sys.get_state(egress)
    _ = :sys.get_state(MDTClient.Vault.Store.whereis(MDTClient.Sandbox.Server, username))
    assert %{listening?: true, port: port} = Sandbox.snapshot(username).proxy
    assert port == proxy.port

    send(egress, :listen)
    _ = :sys.get_state(egress)
    _ = :sys.get_state(MDTClient.Vault.Store.whereis(MDTClient.Sandbox.Server, username))
    assert %{listening?: true, error: nil} = Sandbox.snapshot(username).proxy
  end
end
