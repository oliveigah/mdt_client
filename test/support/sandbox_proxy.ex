defmodule MDTClient.SandboxProxy do
  @moduledoc """
  The sandbox's proxy as microsandbox reaches it, for tests: a listener that
  hands each connection to `MDTClient.Sandbox.Egress.Connection`, and an
  upstream in place of the real host that answers with everything it
  received, byte for byte, after `RECEIVED:`.

      net = SandboxProxy.start(username)
      response = SandboxProxy.https(net, "api.github.com", "GET / HTTP/1.1\\r\\nHost: api.github.com\\r\\n\\r\\n")
  """

  alias MDTClient.Sandbox
  alias MDTClient.Sandbox.CertificateAuthority, as: CA
  alias MDTClient.Sandbox.Egress.Connection

  @doc """
  Starts both for `username`'s sandbox, linked to the caller. Returns the
  proxy's port and the sandbox's CA certificate.
  """
  @spec start(String.t()) :: %{proxy: :inet.port_number(), ca: binary()}
  def start(username) do
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
    %{proxy: port, ca: ca}
  end

  @doc """
  Sends `bytes` to `host` through the proxy, over TLS that trusts only the
  sandbox's CA, and returns everything that comes back until the connection
  closes.
  """
  @spec https(map(), String.t(), iodata()) :: binary()
  def https(%{proxy: proxy, ca: ca}, host, bytes) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", proxy, [:binary, active: false])
    :ok = :gen_tcp.send(socket, "CONNECT 140.82.112.3:443 HTTP/1.1\r\n\r\n")
    {:ok, "HTTP/1.1 200" <> _} = :gen_tcp.recv(socket, 0, 5_000)

    {:ok, tls} =
      :ssl.connect(socket,
        verify: :verify_peer,
        cacerts: [ca],
        server_name_indication: String.to_charlist(host),
        active: false,
        mode: :binary
      )

    :ok = :ssl.send(tls, bytes)
    read_all(tls)
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
      received = read_quiet(socket, "")
      body = "RECEIVED:\n" <> received

      :ssl.send(
        socket,
        "HTTP/1.1 200 OK\r\ncontent-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n#{body}"
      )

      :ssl.close(socket)
    end)

    serve(listen)
  end

  # Everything sent until the other side goes quiet for a moment: the head
  # and whatever follows it.
  defp read_quiet(socket, acc) do
    case :ssl.recv(socket, 0, if(acc == "", do: 5_000, else: 150)) do
      {:ok, data} -> read_quiet(socket, acc <> data)
      {:error, _quiet_or_closed} -> acc
    end
  end

  defp read_all(socket, acc \\ "") do
    case :ssl.recv(socket, 0, 5_000) do
      {:ok, data} -> read_all(socket, acc <> data)
      {:error, _closed} -> acc
    end
  end
end
