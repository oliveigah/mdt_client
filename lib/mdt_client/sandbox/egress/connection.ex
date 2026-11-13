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

  alias MDTClient.Sandbox.{Destinations, Roots, Server}

  @head_limit 64 * 1024
  @body_peek 64 * 1024
  @idle 60_000
  # The driver's own buffer per socket. The default (a few KiB) costs a
  # tunnel about four times the CPU and a quarter of the speed.
  @buffer 262_144
  # microsandbox waits 10 seconds for the answer to a CONNECT.
  @answer_within 3_000
  # A client that speaks first does so at once; after this long MDT also
  # connects, in case the server speaks first.
  @client_first 100
  @server_first 1_400
  @token ~r/\A[!#$%&'*+.^_`|~0-9A-Za-z-]+\z/
  @field_value ~r/\A[\t\x20-\x7e\x80-\xff]*\z/

  @doc """
  Serves `client`, an accepted socket the caller owns.

  ## Options

    * `:upstream` - `fn host -> {:ok, ssl_socket} | {:error, reason} end`, the
      connection a read request is sent on; tests point it elsewhere
    * `:answer_within` - how long, in milliseconds, the sandbox has to answer
      for a destination before the CONNECT is answered and the tunnel waits
      instead (3 seconds)
  """
  def run(client, username, options \\ []) do
    started = System.monotonic_time(:millisecond)

    with {:ok, head, rest} <- read_head(client, :gen_tcp, "", 10_000),
         {:ok, host, port} <- connect_target(head),
         {:ok, ip} <- address(host),
         :ok <- destination(client, username, ip, port, options),
         {from_client, from_server, upstream} <- opening(client, rest, ip, port) do
      sni = sni(from_client)

      if sni && Server.call(username, {:intercept?, sni}) do
        discard(upstream)
        intercept(client, from_client, sni, username, options)
      else
        tunnel(client, from_client, from_server, upstream, {ip, port, sni}, username, started)
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

  # Asks the sandbox whether the VM may connect there. An answer that comes
  # at once is passed on as it is: 200, or 403, which the VM sees as
  # "connection refused". A destination waiting for your approval takes
  # longer than microsandbox waits for a CONNECT, so then the 200 goes out
  # first and the open tunnel waits instead; a "no" closes it.
  defp destination(client, username, ip, port, options) do
    parent = self()
    ref = make_ref()

    spawn_link(fn ->
      send(parent, {ref, Server.call(username, {:destination, ip, port}, :infinity)})
    end)

    receive do
      {^ref, :ok} -> established(client)
      {^ref, {:deny, reason}} -> {:deny, reason}
    after
      Keyword.get(options, :answer_within, @answer_within) ->
        with :ok <- established(client) do
          receive do
            {^ref, :ok} -> :ok
            {^ref, {:deny, _reason}} -> {:error, :denied}
          end
        end
    end
  end

  defp established(client),
    do: :gen_tcp.send(client, "HTTP/1.1 200 Connection Established\r\n\r\n")

  ## The first bytes

  # Who speaks first, as `{from_client, from_server, upstream}`. Most clients
  # do, at once (a TLS ClientHello, an HTTP request), and their first bytes
  # decide between reading and tunnelling. When the client stays quiet for a
  # moment the server probably speaks first (SSH, SMTP, MySQL): MDT connects
  # and takes the first bytes from either side, instead of making the server's
  # greeting wait. `upstream` is the connection made on the way, if any.
  defp opening(client, "", ip, port) do
    case :gen_tcp.recv(client, 0, @client_first) do
      {:ok, data} -> {complete_record(client, data), "", nil}
      {:error, :timeout} -> either(client, connect(ip, port))
      {:error, reason} -> {:error, reason}
    end
  end

  defp opening(client, rest, _ip, _port), do: {complete_record(client, rest), "", nil}

  defp either(_client, {:error, _reason} = failed), do: {"", "", failed}

  defp either(client, {:ok, upstream}) do
    :inet.setopts(client, active: :once)
    :inet.setopts(upstream, active: :once)

    receive do
      {:tcp, ^client, data} -> {complete_record(client, data), "", {:ok, upstream}}
      {:tcp, ^upstream, data} -> {"", data, {:ok, upstream}}
      {tag, ^client} when tag in [:tcp_closed, :tcp_error] -> {:error, :closed}
      {:tcp_error, ^client, reason} -> {:error, reason}
      {:tcp_closed, ^upstream} -> {"", "", {:error, :closed}}
      {:tcp_error, ^upstream, reason} -> {"", "", {:error, reason}}
    after
      @server_first -> {"", "", {:ok, upstream}}
    end
  end

  # A connection made while waiting for the first bytes, not needed after
  # all: closed, and whatever it already delivered dropped.
  defp discard({:ok, upstream}) do
    :gen_tcp.close(upstream)
    forget(upstream)
  end

  defp discard(_none), do: :ok

  defp forget(socket) do
    receive do
      {:tcp, ^socket, _data} -> forget(socket)
      {:tcp_closed, ^socket} -> forget(socket)
      {:tcp_error, ^socket, _reason} -> forget(socket)
    after
      0 -> :ok
    end
  end

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

  ## Tunnels

  defp connect(ip, port) do
    :gen_tcp.connect(
      ip,
      port,
      [:binary, active: false, nodelay: true, buffer: @buffer],
      10_000
    )
  end

  defp tunnel(client, from_client, from_server, upstream, {ip, port, sni}, username, started) do
    case upstream || connect(ip, port) do
      {:ok, upstream} ->
        :inet.setopts(client, buffer: @buffer)
        if from_client != "", do: :ok = :gen_tcp.send(upstream, from_client)
        if from_server != "", do: :ok = :gen_tcp.send(client, from_server)

        {up, down} =
          splice(
            client,
            :gen_tcp,
            upstream,
            :gen_tcp,
            byte_size(from_client),
            byte_size(from_server),
            nil
          )

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
         :ok <- acceptable(method, target, headers, sni) do
      # One Host, and it is the name the connection was encrypted for.
      headers = List.keyreplace(headers, "host", 0, {"host", sni})
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

      {:refuse, status, code, message} ->
        respond(
          tls,
          status,
          Jason.encode!(%{code: code, error: message, by: "MDT agent sandbox"})
        )

      {:error, :bad_request} ->
        respond(
          tls,
          400,
          Jason.encode!(%{
            code: "mdt_bad_request",
            error: "MDT could not read this as one HTTP/1.1 request.",
            by: "MDT agent sandbox"
          })
        )

      {:error, :head_too_large} ->
        respond(
          tls,
          431,
          Jason.encode!(%{
            code: "mdt_bad_request",
            error: "The request's head is over #{div(@head_limit, 1024)} KiB.",
            by: "MDT agent sandbox"
          })
        )

      _closed ->
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
        nodelay: true,
        verify: :verify_peer,
        cacertfile: Roots.file(),
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

  # MDT judges a request by what it read, and the host must act on the same
  # thing. So a request two parsers could read two ways does not go out: its
  # target is a path, it has one Host (the name it was encrypted for, or it
  # could look like GitHub to MDT while going elsewhere), and one way of
  # saying how long its body is. TRACE has the host send the request back,
  # real value included.
  defp acceptable(method, target, headers, sni) do
    hosts = for {"host", value} <- headers, do: String.downcase(value)
    lengths = for {"content-length", value} <- headers, do: value
    encodings = for {"transfer-encoding", value} <- headers, do: String.downcase(value)

    cond do
      method in ["TRACE", "CONNECT"] ->
        {:refuse, 405, "mdt_method_refused", "MDT does not pass on #{method} requests."}

      not (String.starts_with?(target, "/") or (method == "OPTIONS" and target == "*")) ->
        {:refuse, 400, "mdt_bad_request", "The request target must be a path."}

      # What HTTP allows in a target, and what an approval can show as it is.
      not (target =~ ~r/\A[\x21-\x7e]+\z/) ->
        {:refuse, 400, "mdt_bad_request",
         "The request target must be visible ASCII: percent-encode anything else."}

      length(hosts) != 1 ->
        {:refuse, 400, "mdt_bad_request", "A request needs exactly one Host header."}

      hd(hosts) not in [sni, sni <> ":443"] ->
        {:misdirected, hd(hosts)}

      length(lengths) > 1 or (lengths != [] and encodings != []) ->
        {:refuse, 400, "mdt_bad_request",
         "A request says how long its body is once: Content-Length or Transfer-Encoding."}

      lengths != [] and not (hd(lengths) =~ ~r/\A[0-9]+\z/) ->
        {:refuse, 400, "mdt_bad_request", "Content-Length must be a number."}

      encodings not in [[], ["chunked"]] ->
        {:refuse, 400, "mdt_bad_request", "The only Transfer-Encoding passed on is chunked."}

      true ->
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
          if List.keymember?(headers, "transfer-encoding", 0), do: :chunked, else: 0
      end

    if wanted == :chunked, do: read_chunked(tls, rest), else: read_at_least(tls, rest, wanted)
  end

  # A chunked body is read until its last chunk or the peek limit, whichever
  # comes first: a small one ends long before the limit.
  defp read_chunked(tls, acc) do
    if byte_size(acc) >= @body_peek or chunked_whole?(acc) do
      acc
    else
      case :ssl.recv(tls, 0, 2_000) do
        {:ok, data} -> read_chunked(tls, acc <> data)
        {:error, _timeout_or_closed} -> acc
      end
    end
  end

  @doc "Whether these bytes hold a chunked body up to and including its last chunk."
  @spec chunked_whole?(binary()) :: boolean()
  def chunked_whole?(data) do
    with [line, rest] <- :binary.split(data, "\r\n"),
         {size, _extension} <- line |> String.trim() |> Integer.parse(16) do
      cond do
        size == 0 and String.starts_with?(rest, "\r\n") ->
          true

        size == 0 ->
          String.contains?(rest, "\r\n\r\n")

        true ->
          case rest do
            <<_chunk::binary-size(size), "\r\n", more::binary>> -> chunked_whole?(more)
            _short -> false
          end
      end
    else
      # Not a chunk header: nothing to wait for; the host will refuse it.
      :error -> true
      [_no_line_yet] -> false
    end
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
      [head, _rest] when byte_size(head) > @head_limit ->
        {:error, :head_too_large}

      [head, rest] ->
        {:ok, head, rest}

      [_] when byte_size(acc) > @head_limit ->
        {:error, :head_too_large}

      [_] ->
        # A head that ends its lines with line feeds alone never ends for
        # this reader: said at once, instead of waiting for more.
        if :binary.match(acc, "\n\n") != :nomatch do
          {:error, :bad_request}
        else
          case mod.recv(socket, 0, timeout) do
            {:ok, data} -> read_head(socket, mod, acc <> data, timeout)
            {:error, reason} -> {:error, reason}
          end
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

  # Strict on purpose: a line that isn't `name: value`, a name with a space in
  # it, a folded header or a stray CR or LF is where two parsers disagree. A
  # value is what HTTP says one is: visible bytes, spaces and tabs, with the
  # spaces and tabs around it dropped and nothing else.
  defp parse_request(head) do
    [line | lines] = String.split(head, "\r\n")

    with [method, target, version] when version in ["HTTP/1.1", "HTTP/1.0"] <-
           String.split(line, " "),
         true <- method =~ @token,
         {:ok, headers} <- parse_headers(lines, []) do
      {:ok, method, target, version, headers}
    else
      _ -> {:error, :bad_request}
    end
  end

  defp parse_headers([], acc), do: {:ok, Enum.reverse(acc)}

  defp parse_headers([line | rest], acc) do
    with [name, value] <- String.split(line, ":", parts: 2),
         true <- name =~ @token,
         true <- value =~ @field_value do
      value = String.replace(value, ~r/\A[ \t]+|[ \t]+\z/, "")
      parse_headers(rest, [{String.downcase(name), value} | acc])
    else
      _ -> :error
    end
  end

  ## The ClientHello

  @doc """
  The host a TLS ClientHello names, if the bytes are one and the name is a
  host name: letters, digits, dots, dashes and underscores, as names are on
  the wire (others travel as punycode). Any other bytes name nothing, and
  the connection is passed through unread under its address.
  """
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
        name = String.downcase(name)
        if name =~ ~r/\A[a-z0-9_]([a-z0-9_.-]{0,251}[a-z0-9_])?\z/, do: name

      _ ->
        nil
    end
  end

  defp server_name(<<_type::16, length::16, _::binary-size(length), rest::binary>>),
    do: server_name(rest)

  defp server_name(_), do: nil
end
