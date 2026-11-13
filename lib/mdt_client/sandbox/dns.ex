defmodule MDTClient.Sandbox.Dns do
  @moduledoc """
  The DNS forwarder: every name the VM looks up goes through here.

  microsandbox is told `--dns-nameserver 127.0.0.1:5353`, a port that exists
  only in its bubble, where the relay passes each question to this socket
  (`dns.sock`), framed as DNS over TCP is: two bytes of length, then the
  message. The bubble has no other network, so a question the VM aims at
  another resolver gets no answer.

  Each question is passed to this machine's own resolver (the first
  `nameserver` of `/etc/resolv.conf`, so VPN names keep working) and its
  answer returned unchanged. An answer cut short over UDP is asked again
  over TCP. The name and type are read for the activity log, where a name is
  logged again only after `@quiet` seconds; nothing else in the message is
  looked at. A question it can't read is dropped.

  One listener per unlocked identity. When it is not listening, the VM
  resolves nothing.
  """

  use GenServer

  require Logger

  alias MDTClient.Sandbox.{Server, Sockets}
  alias MDTClient.Vault.Store

  @answer_within 5_000
  @idle 60_000
  @quiet 600
  @seen_limit 20_000
  @types %{
    1 => "A",
    28 => "AAAA",
    5 => "CNAME",
    15 => "MX",
    16 => "TXT",
    33 => "SRV",
    12 => "PTR",
    2 => "NS",
    6 => "SOA",
    65 => "HTTPS",
    64 => "SVCB"
  }

  @doc "Starts the forwarder of one unlocked identity."
  def start_link(opts) do
    username = Keyword.fetch!(opts, :username)
    GenServer.start_link(__MODULE__, username, name: Store.via(__MODULE__, username))
  end

  @doc false
  def child_spec(opts) do
    %{id: {__MODULE__, Keyword.fetch!(opts, :username)}, start: {__MODULE__, :start_link, [opts]}}
  end

  @doc "The Unix socket one identity's forwarder listens on (`MDTClient.Sandbox.Sockets`)."
  @spec path(String.t()) :: Path.t()
  def path(username), do: Sockets.path(username, "dns.sock")

  @doc """
  The name and type a DNS message asks for, or `:error` when it isn't a
  question this can read.

      iex> question = <<0x12, 0x34, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 7, "example", 3, "com", 0, 0, 1, 0, 1>>
      iex> MDTClient.Sandbox.Dns.question(question)
      {:ok, "example.com", "A"}
  """
  @spec question(binary()) :: {:ok, String.t(), String.t()} | :error
  def question(<<_id::16, _flags::16, 1::16, _counts::48, rest::binary>>) do
    with {:ok, labels, <<type::16, _class::16, _::binary>>} <- labels(rest, []) do
      {:ok, labels |> Enum.join(".") |> String.downcase(), Map.get(@types, type, "type #{type}")}
    end
  end

  def question(_message), do: :error

  defp labels(<<0, rest::binary>>, acc), do: {:ok, Enum.reverse(acc), rest}

  defp labels(<<size, label::binary-size(size), rest::binary>>, acc)
       when size in 1..63 and length(acc) < 128 do
    # Visible ASCII, as names are on the wire: the name goes into the log.
    if label =~ ~r/\A[\x21-\x7e]+\z/, do: labels(rest, [label | acc]), else: :error
  end

  defp labels(_other, _acc), do: :error

  @doc """
  The address questions are passed to: this machine's own resolver. Tests
  set `config :mdt_client, MDTClient.Sandbox.Dns, resolver: {address, port}`.
  """
  @spec resolver() :: {:inet.ip_address(), :inet.port_number()}
  def resolver do
    case Application.get_env(:mdt_client, __MODULE__, [])[:resolver] do
      nil -> system_resolver()
      resolver -> resolver
    end
  end

  defp system_resolver do
    with {:ok, text} <- File.read("/etc/resolv.conf"),
         [address | _] <-
           for(
             line <- String.split(text, "\n"),
             ["nameserver", address] <- [String.split(line)],
             {:ok, ip} <- [:inet.parse_address(String.to_charlist(address))],
             do: ip
           ) do
      {address, 53}
    else
      _ -> {{127, 0, 0, 53}, 53}
    end
  end

  @impl true
  def init(username) do
    Process.flag(:trap_exit, true)
    Sockets.ensure!(username)
    path = path(username)
    File.rm(path)
    seen = :ets.new(:seen, [:set, :public])

    case :gen_tcp.listen(0, [:binary, ifaddr: {:local, path}, active: false, backlog: 256]) do
      {:ok, socket} ->
        File.chmod(path, 0o600)
        acceptor = spawn_link(fn -> accept(socket, username, seen) end)
        {:ok, %{username: username, path: path, socket: socket, acceptor: acceptor}}

      {:error, reason} ->
        Logger.warning("sandbox DNS could not listen on #{path}: #{inspect(reason)}",
          system: :sandbox
        )

        {:ok, %{username: username, path: path, socket: nil, acceptor: nil}}
    end
  end

  @impl true
  def handle_info({:EXIT, pid, reason}, %{acceptor: pid} = state), do: {:stop, reason, state}
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.socket, do: :gen_tcp.close(state.socket)
    File.rm(state.path)
    :ok
  end

  defp accept(socket, username, seen) do
    case :gen_tcp.accept(socket) do
      {:ok, client} ->
        {:ok, pid} =
          Task.Supervisor.start_child(MDTClient.Sandbox.TaskSupervisor, fn ->
            receive do
              :go -> serve(client, username, seen)
            after
              5_000 -> :ok
            end
          end)

        :ok = :gen_tcp.controlling_process(client, pid)
        send(pid, :go)
        accept(socket, username, seen)

      {:error, :closed} ->
        exit(:normal)

      {:error, reason} ->
        exit(reason)
    end
  end

  # One connection carries one question (from UDP in the VM) or several
  # (from TCP there).
  defp serve(client, username, seen) do
    with {:ok, <<size::16>>} <- :gen_tcp.recv(client, 2, @idle),
         {:ok, message} <- :gen_tcp.recv(client, size, @answer_within),
         {:ok, name, type} <- question(message),
         :ok <- note(username, seen, name, type),
         {:ok, answer} <- forward(message),
         :ok <- :gen_tcp.send(client, [<<byte_size(answer)::16>>, answer]) do
      serve(client, username, seen)
    else
      _closed_unreadable_or_unanswered -> :gen_tcp.close(client)
    end
  end

  defp note(username, seen, name, type) do
    now = System.monotonic_time(:second)

    case :ets.lookup(seen, {name, type}) do
      [{_key, at}] when now - at < @quiet ->
        :ok

      _new_or_old ->
        # The names are the VM's to make up: the table starts over before it
        # grows without end, at the cost of logging some names twice.
        if :ets.info(seen, :size) >= @seen_limit, do: :ets.delete_all_objects(seen)
        :ets.insert(seen, {{name, type}, now})

        Server.cast(
          username,
          {:log, %{outcome: :lookup, summary: "Looked up (#{type})", host: name}}
        )
    end
  end

  defp forward(message) do
    {address, port} = resolver()
    family = if tuple_size(address) == 8, do: :inet6, else: :inet

    with {:ok, socket} <- :gen_udp.open(0, [:binary, family, active: false]) do
      answer =
        with :ok <- :gen_udp.send(socket, address, port, message),
             {:ok, {_from, _port, answer}} <- :gen_udp.recv(socket, 0, @answer_within) do
          {:ok, answer}
        end

      :gen_udp.close(socket)

      case answer do
        # Cut short (TC): the whole answer needs TCP.
        {:ok, <<_id::16, _::6, 1::1, _::9, _::binary>>} ->
          over_tcp(address, port, family, message)

        other ->
          other
      end
    end
  end

  defp over_tcp(address, port, family, message) do
    with {:ok, socket} <-
           :gen_tcp.connect(
             address,
             port,
             [:binary, family, active: false, packet: 2],
             @answer_within
           ) do
      answer =
        with :ok <- :gen_tcp.send(socket, message) do
          :gen_tcp.recv(socket, 0, @answer_within)
        end

      :gen_tcp.close(socket)
      answer
    end
  end
end
