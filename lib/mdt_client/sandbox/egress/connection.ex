defmodule MDTClient.Sandbox.Egress.Connection do
  @moduledoc """
  One connection the VM opened, from microsandbox's CONNECT to its close.

    1. The destination is checked with the sandbox (`refused`, `private` and
       network grants), which may hold it for your approval.
    2. The first bytes are peeked. A TLS ClientHello names its host (SNI).
    3. A host some credential grant lists is **read**: MDT finishes TLS with
       a certificate from its own CA, offering HTTP/1.1 only, reads the
       request, and asks the sandbox whether it may go out and with what.
       Everything else is **tunnelled** as bytes, unread.

  Read requests go out one per connection (`connection: close`), so every
  request is judged on its own and turning a grant off takes effect on the
  next one. The upstream connection is MDT's own: it resolves the host and
  verifies its certificate, and the address the VM asked for is ignored, so
  a forged lookup in the VM cannot redirect a credential.

  If the real value shows up in the response headers, it is replaced with the
  placeholder before the VM sees it.
  """

  require Logger

  alias MDTClient.Sandbox.{Destinations, Server}

  @head_limit 64 * 1024
  @body_peek 64 * 1024
  @idle 60_000

  @doc """
  Serves `client`, an accepted socket the caller owns.

  ## Options

    * `:upstream` - `fn host -> {:ok, ssl_socket} | {:error, reason} end`, the
      connection a read request is sent on; tests point it elsewhere
  """
  def run(client, username, options \\ []) do
    started = System.monotonic_time(:millisecond)

    with {:ok, head, rest} <- read_head(client, :gen_tcp, "", 10_000),
         {:ok, host, port} <- connect_target(head),
         {:ok, ip} <- address(host),
         :ok <- destination(username, ip, port) do
      :ok = :gen_tcp.send(client, "HTTP/1.1 200 Connection Established\r\n\r\n")
      first = peek(client, rest)
      sni = sni(first)

      if sni && Server.call(username, {:intercept?, sni}) do
        intercept(client, first, sni, username, options)
      else
        tunnel(client, first, ip, port, sni, username, started)
      end
    else
      {:deny, _reason} ->
        :gen_tcp.send(client, "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n")
        :gen_tcp.close(client)

      _error ->
        :gen_tcp.close(client)
    end
  rescue
    error ->
      Logger.debug("sandbox connection ended: #{Exception.message(error)}", system: :sandbox)
      :gen_tcp.close(client)
  catch
    :exit, reason ->
      Logger.debug("sandbox connection ended: #{inspect(reason)}", system: :sandbox)
      :gen_tcp.close(client)
  end

  defp destination(username, ip, port) do
    Server.call(username, {:destination, ip, port}, :infinity)
  end

  ## Tunnels

  defp tunnel(client, first, ip, port, sni, username, started) do
    case :gen_tcp.connect(ip, port, [:binary, active: false, nodelay: true], 10_000) do
      {:ok, upstream} ->
        if first != "", do: :ok = :gen_tcp.send(upstream, first)
        {up, down} = splice(client, :gen_tcp, upstream, :gen_tcp, byte_size(first), 0, nil)

        Server.cast(
          username,
          {:log,
           %{
             outcome: :tunnel,
             summary: "Passed through",
             host: sni || "#{:inet.ntoa(ip)}",
             port: port,
             up: up,
             down: down,
             ms: System.monotonic_time(:millisecond) - started
           }}
        )

      {:error, reason} ->
        Server.cast(
          username,
          {:log,
           %{
             outcome: :blocked,
             summary: "Could not connect: #{:inet.format_error(reason)}",
             host: sni || "#{:inet.ntoa(ip)}",
             port: port
           }}
        )

        :gen_tcp.close(client)
    end
  end

  ## Read requests

  defp intercept(client, first, sni, username, options) do
    :ok = :gen_tcp.unrecv(client, first)
    certificate = Server.call(username, {:leaf, sni})

    {:ok, tls} =
      :ssl.handshake(
        client,
        certificate ++
          [
            alpn_preferred_protocols: ["http/1.1"],
            versions: [:"tlsv1.3", :"tlsv1.2"],
            active: false,
            mode: :binary
          ],
        10_000
      )

    with {:ok, head, rest} <- read_head(tls, :ssl, "", @idle),
         {:ok, method, target, version, headers} <- parse_request(head),
         :ok <- same_host(headers, sni) do
      {headers, rest} = continue_if_expected(tls, headers, rest)
      body = read_body_prefix(tls, headers, rest)

      request = %{host: sni, method: method, path: target, headers: headers, body: body}

      case Server.call(username, {:authorize, request}, :infinity) do
        {:forward, headers, scrub} ->
          send_upstream(tls, sni, method, target, version, headers, body, scrub, options)

        {:deny, status, json} ->
          respond(tls, status, json)
      end
    else
      {:misdirected, host} ->
        respond(
          tls,
          421,
          Jason.encode!(%{error: "Host #{host} does not match #{sni}.", by: "MDT agent sandbox"})
        )

      _closed_or_bad ->
        :ssl.close(tls)
    end
  end

  defp send_upstream(tls, sni, method, target, version, headers, body, scrub, options) do
    connect = Keyword.get(options, :upstream, &upstream/1)

    case connect.(sni) do
      {:ok, upstream} ->
        upgrade? = Enum.any?(headers, fn {name, _} -> name == "upgrade" end)

        headers =
          headers
          |> Enum.reject(fn {name, _} ->
            name in ["proxy-connection", "keep-alive"] or (name == "connection" and not upgrade?)
          end)
          |> then(&if(upgrade?, do: &1, else: &1 ++ [{"connection", "close"}]))

        head = [
          method,
          " ",
          target,
          " ",
          version,
          "\r\n",
          Enum.map(headers, fn {k, v} -> [k, ": ", v, "\r\n"] end),
          "\r\n"
        ]

        :ok = :ssl.send(upstream, [head, body])
        splice(tls, :ssl, upstream, :ssl, 0, 0, scrub)

      {:error, reason} ->
        respond(
          tls,
          502,
          Jason.encode!(%{
            error: "Could not reach #{sni}: #{inspect(reason)}",
            by: "MDT agent sandbox"
          })
        )
    end
  end

  defp upstream(host) do
    charlist = String.to_charlist(host)

    :ssl.connect(
      charlist,
      443,
      [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        server_name_indication: charlist,
        customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)],
        alpn_advertised_protocols: ["http/1.1"],
        depth: 10,
        active: false,
        mode: :binary
      ],
      15_000
    )
  end

  defp respond(tls, status, json) do
    reason = Plug.Conn.Status.reason_phrase(status)

    :ssl.send(tls, [
      "HTTP/1.1 #{status} #{reason}\r\ncontent-type: application/json\r\ncontent-length: #{byte_size(json)}\r\nconnection: close\r\n\r\n",
      json
    ])

    :ssl.close(tls)
  end

  # The request must be for the host it was encrypted for; otherwise a
  # request could look like GitHub to MDT while going elsewhere.
  defp same_host(headers, sni) do
    case List.keyfind(headers, "host", 0) do
      {_, host} ->
        bare = host |> String.split(":") |> hd() |> String.downcase()
        if bare == String.downcase(sni), do: :ok, else: {:misdirected, host}

      nil ->
        :ok
    end
  end

  # Answers 100 Continue ourselves, so the start of the body arrives before
  # the decision; the upstream then never sees the expectation.
  defp continue_if_expected(tls, headers, rest) do
    case List.keyfind(headers, "expect", 0) do
      {_, value} ->
        if String.downcase(value) == "100-continue" do
          :ssl.send(tls, "HTTP/1.1 100 Continue\r\n\r\n")
          {List.keydelete(headers, "expect", 0), rest}
        else
          {headers, rest}
        end

      nil ->
        {headers, rest}
    end
  end

  defp read_body_prefix(tls, headers, rest) do
    wanted =
      case List.keyfind(headers, "content-length", 0) do
        {_, length} ->
          case Integer.parse(length) do
            {n, _} -> min(n, @body_peek)
            :error -> 0
          end

        nil ->
          if List.keymember?(headers, "transfer-encoding", 0), do: @body_peek, else: 0
      end

    read_at_least(tls, rest, wanted)
  end

  defp read_at_least(_tls, acc, wanted) when byte_size(acc) >= wanted, do: acc

  defp read_at_least(tls, acc, wanted) do
    case :ssl.recv(tls, 0, 2_000) do
      {:ok, data} -> read_at_least(tls, acc <> data, wanted)
      {:error, _timeout_or_closed} -> acc
    end
  end

  ## Moving bytes

  # Copies both ways until either side closes. With `scrub`, the first
  # response head from upstream has each real value replaced by its
  # placeholder before it reaches the VM.
  defp splice(a, a_mod, b, b_mod, up, down, scrub) do
    set_active(a, a_mod)
    set_active(b, b_mod)
    loop(a, a_mod, b, b_mod, up, down, if(scrub in [nil, []], do: nil, else: {scrub, ""}))
  end

  defp loop(a, a_mod, b, b_mod, up, down, scrubbing) do
    receive do
      {tag, ^a, data} when tag in [:tcp, :ssl] ->
        b_mod.send(b, data)
        set_active(a, a_mod)
        loop(a, a_mod, b, b_mod, up + byte_size(data), down, scrubbing)

      {tag, ^b, data} when tag in [:tcp, :ssl] ->
        {out, scrubbing} = scrub_head(data, scrubbing)
        if out != "", do: a_mod.send(a, out)
        set_active(b, b_mod)
        loop(a, a_mod, b, b_mod, up, down + byte_size(data), scrubbing)

      {tag, _socket} when tag in [:tcp_closed, :ssl_closed] ->
        finish(a, a_mod, b, b_mod, up, down, scrubbing)

      {tag, _socket, _reason} when tag in [:tcp_error, :ssl_error] ->
        finish(a, a_mod, b, b_mod, up, down, scrubbing)
    after
      @idle * 5 -> finish(a, a_mod, b, b_mod, up, down, scrubbing)
    end
  end

  defp finish(a, a_mod, b, b_mod, up, down, scrubbing) do
    case scrubbing do
      {_pairs, pending} when pending != "" -> a_mod.send(a, pending)
      _ -> :ok
    end

    a_mod.close(a)
    b_mod.close(b)
    {up, down}
  end

  defp scrub_head(data, nil), do: {data, nil}

  defp scrub_head(data, {pairs, pending}) do
    buffered = pending <> data

    case :binary.split(buffered, "\r\n\r\n") do
      [head, body] ->
        clean =
          Enum.reduce(pairs, head, fn {value, placeholder}, acc ->
            String.replace(acc, value, placeholder)
          end)

        {[clean, "\r\n\r\n", body], nil}

      [_partial] when byte_size(buffered) > @head_limit ->
        {buffered, nil}

      [_partial] ->
        {"", {pairs, buffered}}
    end
  end

  defp set_active(socket, :gen_tcp), do: :inet.setopts(socket, active: :once)
  defp set_active(socket, :ssl), do: :ssl.setopts(socket, active: :once)

  ## Parsing

  defp read_head(socket, mod, acc, timeout) do
    case :binary.split(acc, "\r\n\r\n") do
      [head, rest] ->
        {:ok, head, rest}

      [_] when byte_size(acc) > @head_limit ->
        {:error, :head_too_large}

      [_] ->
        case mod.recv(socket, 0, timeout) do
          {:ok, data} -> read_head(socket, mod, acc <> data, timeout)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp connect_target(head) do
    with [line | _] <- String.split(head, "\r\n"),
         ["CONNECT", target, _version] <- String.split(line, " "),
         [port | reversed] <- target |> String.split(":") |> Enum.reverse(),
         {port, ""} <- Integer.parse(port) do
      {:ok, reversed |> Enum.reverse() |> Enum.join(":"), port}
    else
      _ -> {:error, :not_connect}
    end
  end

  defp address(host) do
    case Destinations.parse_ip(host) do
      {:ok, ip} ->
        {:ok, ip}

      :error ->
        case Destinations.resolve(host) do
          [ip | _] -> {:ok, ip}
          [] -> {:error, :unresolved}
        end
    end
  end

  defp parse_request(head) do
    [line | lines] = String.split(head, "\r\n")

    with [method, target, "HTTP/1." <> _ = version] <- String.split(line, " ") do
      headers =
        for header <- lines, [name, value] <- [String.split(header, ":", parts: 2)] do
          {String.downcase(String.trim(name)), String.trim(value)}
        end

      {:ok, method, target, version, headers}
    else
      _ -> {:error, :bad_request}
    end
  end

  ## The first bytes

  # Servers that speak first (SSH, SMTP) send nothing from the client side;
  # a short wait tells them apart.
  defp peek(client, "") do
    case :gen_tcp.recv(client, 0, 1_500) do
      {:ok, data} -> complete_record(client, data)
      {:error, _timeout} -> ""
    end
  end

  defp peek(client, rest), do: complete_record(client, rest)

  # A ClientHello can span TCP segments (post-quantum key shares make it
  # large), so read until the TLS record is whole.
  defp complete_record(client, <<0x16, _major, _minor, length::16, _::binary>> = data)
       when byte_size(data) < length + 5 do
    case :gen_tcp.recv(client, 0, 5_000) do
      {:ok, more} -> complete_record(client, data <> more)
      {:error, _} -> data
    end
  end

  defp complete_record(_client, data), do: data

  @doc "The host a TLS ClientHello names, if the bytes are one."
  @spec sni(binary()) :: String.t() | nil
  def sni(<<0x16, _major, _minor, length::16, record::binary-size(length), _::binary>>) do
    with <<1, _hlen::24, _version::16, _random::binary-32, sid_len, _sid::binary-size(sid_len),
           cs_len::16, _cs::binary-size(cs_len), comp_len, _comp::binary-size(comp_len),
           ext_len::16, extensions::binary-size(ext_len), _::binary>> <- record do
      server_name(extensions)
    else
      _ -> nil
    end
  end

  def sni(_data), do: nil

  defp server_name(<<0::16, length::16, data::binary-size(length), _rest::binary>>) do
    case data do
      <<_list::16, 0, name_length::16, name::binary-size(name_length), _::binary>> ->
        String.downcase(name)

      _ ->
        nil
    end
  end

  defp server_name(<<_type::16, length::16, _::binary-size(length), rest::binary>>),
    do: server_name(rest)

  defp server_name(_), do: nil
end
