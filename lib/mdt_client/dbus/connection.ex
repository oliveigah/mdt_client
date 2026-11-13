defmodule MDTClient.DBus.Connection do
  @moduledoc """
  A connection to a D-Bus bus, by default the session bus of the desktop MDT
  runs in.

  It connects, authenticates as this process's user (`EXTERNAL`, which the
  bus checks against the socket's peer credentials) and says `Hello` before
  `start_link/1` returns, so a started connection has a unique name
  (`unique_name/1`). `call/3` sends a method call and waits for its return;
  `send_message/2` sends anything else. Signals and method calls addressed
  to it go to its owner as `{:dbus_signal, conn, message}` and
  `{:dbus_method_call, conn, message}`. Returns nobody waits for any more are
  dropped.

  It is linked to whoever started it, which hears when it stops: when the
  bus closes it (`{:shutdown, :closed}`) or its stream can't be read. A
  message whose values don't fit its signature is refused with
  `{:error, {:invalid, text}}` and the connection carries on.

  Only Unix socket addresses (`unix:path=`, `unix:abstract=`) are supported:
  desktop session buses use nothing else.
  """

  use GenServer

  alias MDTClient.DBus.Message

  @bus "org.freedesktop.DBus"
  @connect_timeout 5_000

  @type address :: :session | String.t()

  @doc """
  Connects. Options:

    * `:address` - a D-Bus address, or `:session` (the default) for the
      session bus (`session_address/0`);
    * `:owner` - who hears signals and calls, the caller by default.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    opts = Keyword.put_new(opts, :owner, self())
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Sends `message`, a method call, and waits up to `timeout` for its answer:
  the return, or `{:error, {:dbus, name, text}}` for an error.
  """
  @spec call(GenServer.server(), Message.t(), timeout()) ::
          {:ok, Message.t()}
          | {:error,
             {:dbus, String.t(), String.t()} | {:invalid, String.t()} | :timeout | :closed}
  def call(conn, %Message{type: :method_call} = message, timeout \\ 5_000),
    do: GenServer.call(conn, {:call, message, timeout}, :infinity)

  @doc "Sends `message` without waiting for anything back."
  @spec send_message(GenServer.server(), Message.t()) ::
          :ok | {:error, {:invalid, String.t()} | :closed}
  def send_message(conn, %Message{} = message), do: GenServer.call(conn, {:send, message})

  @doc "The name the bus gave this connection."
  @spec unique_name(GenServer.server()) :: String.t()
  def unique_name(conn), do: GenServer.call(conn, :unique_name)

  @doc """
  The session bus's address: `DBUS_SESSION_BUS_ADDRESS`, or the socket
  systemd puts in `XDG_RUNTIME_DIR` when that isn't set.
  """
  @spec session_address() :: {:ok, String.t()} | {:error, :no_session_bus}
  def session_address do
    runtime = System.get_env("XDG_RUNTIME_DIR")

    case System.get_env("DBUS_SESSION_BUS_ADDRESS") do
      address when is_binary(address) and address != "" ->
        {:ok, address}

      _unset when is_binary(runtime) and runtime != "" ->
        path = Path.join(runtime, "bus")
        if File.exists?(path), do: {:ok, "unix:path=" <> path}, else: {:error, :no_session_bus}

      _unset ->
        {:error, :no_session_bus}
    end
  end

  @doc """
  The socket of the first Unix address in `address`, as `:gen_tcp` takes it.

      iex> MDTClient.DBus.Connection.socket_address("unix:path=/run/user/1000/bus")
      {:ok, {:local, "/run/user/1000/bus"}}

  """
  @spec socket_address(String.t()) :: {:ok, {:local, binary()}} | {:error, :unsupported_address}
  def socket_address(address) do
    address
    |> String.split(";", trim: true)
    |> Enum.find_value({:error, :unsupported_address}, fn entry ->
      with "unix:" <> keys <- entry,
           pairs = keys |> String.split(",") |> Enum.map(&String.split(&1, "=", parts: 2)),
           socket when socket != nil <- unix_socket(pairs) do
        {:ok, socket}
      else
        _other -> nil
      end
    end)
  end

  defp unix_socket(pairs) do
    Enum.find_value(pairs, fn
      ["path", path] -> {:local, URI.decode(path)}
      ["abstract", name] -> {:local, <<0>> <> URI.decode(name)}
      _other -> nil
    end)
  end

  ## Server

  @impl true
  def init(opts) do
    owner = Keyword.fetch!(opts, :owner)
    deadline = System.monotonic_time(:millisecond) + @connect_timeout

    with {:ok, address} <- resolve(Keyword.get(opts, :address, :session)),
         {:ok, socket_address} <- socket_address(address),
         {:ok, socket} <- connect(socket_address, deadline),
         :ok <- authenticate(socket, deadline),
         {:ok, name, buffer} <- hello(socket, deadline) do
      :ok = :inet.setopts(socket, active: :once)
      state = %{socket: socket, owner: owner, name: name, serial: 1, pending: %{}, buffer: <<>>}
      {:ok, receive_buffer(state, buffer)}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  defp resolve(:session), do: session_address()
  defp resolve(address) when is_binary(address), do: {:ok, address}

  defp connect(socket_address, deadline) do
    case :gen_tcp.connect(socket_address, 0, [:binary, active: false], left(deadline)) do
      {:ok, socket} -> {:ok, socket}
      {:error, reason} -> {:error, {:connect, reason}}
    end
  end

  # SASL as the spec has it: a NUL byte, then lines. EXTERNAL names the
  # user as the hex of its decimal uid.
  defp authenticate(socket, deadline) do
    with {:ok, uid} <- uid(),
         :ok <-
           :gen_tcp.send(socket, <<0>> <> "AUTH EXTERNAL #{Base.encode16(uid, case: :lower)}\r\n"),
         {:ok, "OK " <> _guid} <- line(socket, <<>>, deadline),
         :ok <- :gen_tcp.send(socket, "BEGIN\r\n") do
      :ok
    else
      {:ok, refused} -> {:error, {:auth, String.trim(refused)}}
      {:error, reason} -> {:error, {:auth, reason}}
    end
  end

  defp uid do
    with {:ok, status} <- File.read("/proc/self/status"),
         [_, uid] <- Regex.run(~r/^Uid:\s+(\d+)/m, status) do
      {:ok, uid}
    else
      _other ->
        case System.cmd("id", ["-u"], stderr_to_stdout: true) do
          {uid, 0} -> {:ok, String.trim(uid)}
          _failed -> {:error, :no_uid}
        end
    end
  end

  defp line(socket, acc, deadline) do
    case :binary.split(acc, "\r\n") do
      [line, _rest] ->
        {:ok, line}

      [_partial] ->
        case :gen_tcp.recv(socket, 0, left(deadline)) do
          {:ok, data} when byte_size(acc) < 4_096 -> line(socket, acc <> data, deadline)
          {:ok, _data} -> {:error, :line_too_long}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp hello(socket, deadline) do
    hello = Message.call(@bus, "/org/freedesktop/DBus", @bus, "Hello")

    with :ok <- :gen_tcp.send(socket, Message.encode(hello, 1)) do
      await_hello(socket, <<>>, deadline)
    end
  end

  defp await_hello(socket, buffer, deadline) do
    case Message.decode(buffer) do
      {:ok, %Message{reply_serial: 1, type: :method_return, body: [name]}, rest} ->
        {:ok, name, rest}

      {:ok, %Message{reply_serial: 1, type: :error, error_name: error}, _rest} ->
        {:error, {:hello, error}}

      {:ok, _other, rest} ->
        await_hello(socket, rest, deadline)

      :more ->
        case :gen_tcp.recv(socket, 0, left(deadline)) do
          {:ok, data} -> await_hello(socket, buffer <> data, deadline)
          {:error, reason} -> {:error, {:hello, reason}}
        end

      {:error, reason} ->
        {:error, {:hello, reason}}
    end
  end

  defp left(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  @impl true
  def handle_call({:call, message, timeout}, from, state) do
    {serial, state} = next_serial(state)

    case send_encoded(state, message, serial) do
      :ok ->
        timer = Process.send_after(self(), {:call_timeout, serial}, timeout)
        {:noreply, put_in(state.pending[serial], {from, timer})}

      {:invalid, _text} = invalid ->
        {:reply, {:error, invalid}, state}

      {:error, reason} ->
        {:stop, {:shutdown, reason}, {:error, :closed}, state}
    end
  end

  def handle_call({:send, message}, _from, state) do
    {serial, state} = next_serial(state)

    case send_encoded(state, message, serial) do
      :ok -> {:reply, :ok, state}
      {:invalid, _text} = invalid -> {:reply, {:error, invalid}, state}
      {:error, reason} -> {:stop, {:shutdown, reason}, {:error, :closed}, state}
    end
  end

  def handle_call(:unique_name, _from, state), do: {:reply, state.name, state}

  @impl true
  def handle_info({:tcp, socket, data}, %{socket: socket} = state) do
    :ok = :inet.setopts(socket, active: :once)
    {:noreply, receive_buffer(state, state.buffer <> data)}
  end

  def handle_info({:tcp_closed, socket}, %{socket: socket} = state),
    do: {:stop, {:shutdown, :closed}, state}

  def handle_info({:tcp_error, socket, reason}, %{socket: socket} = state),
    do: {:stop, {:shutdown, reason}, state}

  def handle_info({:call_timeout, serial}, state) do
    case Map.pop(state.pending, serial) do
      {{from, _timer}, pending} ->
        GenServer.reply(from, {:error, :timeout})
        {:noreply, %{state | pending: pending}}

      {nil, _pending} ->
        {:noreply, state}
    end
  end

  def handle_info({:stop, reason}, state), do: {:stop, reason, state}

  defp receive_buffer(state, buffer) do
    case Message.decode(buffer) do
      {:ok, message, rest} ->
        state |> dispatch(message) |> receive_buffer(rest)

      :more ->
        %{state | buffer: buffer}

      {:error, reason} ->
        send(self(), {:stop, {:shutdown, {:bad_stream, reason}}})
        %{state | buffer: <<>>}
    end
  end

  defp dispatch(state, %Message{type: type, reply_serial: serial} = message)
       when type in [:method_return, :error] do
    case Map.pop(state.pending, serial) do
      {{from, timer}, pending} ->
        Process.cancel_timer(timer)
        GenServer.reply(from, answer(message))
        %{state | pending: pending}

      {nil, _pending} ->
        state
    end
  end

  defp dispatch(state, %Message{type: :signal} = message) do
    send(state.owner, {:dbus_signal, self(), message})
    state
  end

  defp dispatch(state, %Message{type: :method_call} = message) do
    send(state.owner, {:dbus_method_call, self(), message})
    state
  end

  defp dispatch(state, _unknown_type), do: state

  defp answer(%Message{type: :method_return} = message), do: {:ok, message}

  defp answer(%Message{type: :error, error_name: name, body: body}) do
    text = with [text | _] when is_binary(text) <- body, do: text, else: (_ -> "")
    {:error, {:dbus, name, text}}
  end

  defp next_serial(state), do: {state.serial + 1, %{state | serial: state.serial + 1}}

  defp send_encoded(state, message, serial) do
    :gen_tcp.send(state.socket, Message.encode(message, serial))
  rescue
    error in [ArgumentError, KeyError] -> {:invalid, Exception.message(error)}
  end
end
