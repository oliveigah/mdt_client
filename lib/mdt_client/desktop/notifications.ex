defmodule MDTClient.Desktop.Notifications do
  @moduledoc """
  Notifications on the desktop MDT runs in, through the freedesktop
  notification service on the session bus (GNOME Shell's, on GNOME).

  One connection (`MDTClient.DBus.Connection`) serves the whole app and stays
  open while MDT runs. GNOME sends a notification's clicks only to the
  connection that showed it, and removes an app's notifications as soon as
  that connection closes, so a short-lived sender such as `notify-send`
  can't do this.

  Whoever shows a notification picks its key; showing the same key again
  updates it in place. A notification belongs to the process that showed
  it and closes when that process ends, so a locked vault leaves none
  behind. When you dismiss one, it is forgotten: closing its key later does
  nothing.

  A notice is `%{summary:, body:, scope:, open:}`: plain text (the body is
  escaped for GNOME, which reads it as markup), the username it is for, and
  the MDT path a click opens. A click is told to that identity's pages
  (`subscribe/1`) as `{:desktop_open, path, token}`; `token` is the
  activation token the desktop sent with the click, which a Wayland window
  needs to come forward, or nil.

  GNOME attributes the notifications to MDT's desktop entry (`MDT.desktop`,
  which the packages install), so they carry MDT's name and icon and follow
  its switch in GNOME's notification settings. Signals are taken only from
  the service that showed the notification.

  With no session bus (a server, a remote shell) or no notification
  service, it keeps track of what it would show, so `list/1` answers the
  same, and tries again every `:retry_every` milliseconds. With
  `address: nil` (tests) it never connects.
  """

  use GenServer

  require Logger

  alias MDTClient.Accounts
  alias MDTClient.DBus.{Connection, Message}

  @service "org.freedesktop.Notifications"
  @path "/org/freedesktop/Notifications"
  @app_name "MDT"
  @desktop_entry "MDT"
  @summary_limit 120
  @body_limit 400

  @type key :: term()

  @type notice :: %{
          summary: String.t(),
          body: String.t(),
          scope: String.t(),
          open: String.t()
        }

  @type status ::
          :off
          | :connecting
          | {:connected, %{name: String.t(), vendor: String.t(), version: String.t()}}
          | {:unavailable, String.t()}

  ## Client

  @doc """
  Starts the service. Options: `:name`; `:address`, a D-Bus address,
  `:session` or nil (by default from `config :mdt_client, #{inspect(__MODULE__)}`,
  else `:session`); `:retry_every` in milliseconds (30 seconds).
  """
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Shows `notice` under `key`, or updates the one shown under it. It belongs
  to the calling process.
  """
  @spec show(GenServer.server(), key(), notice()) :: :ok
  def show(server \\ __MODULE__, key, %{} = notice),
    do: GenServer.cast(server, {:show, key, clean(notice), self()})

  @doc "Closes the notification shown under `key`, if there is one."
  @spec close(GenServer.server(), key()) :: :ok
  def close(server \\ __MODULE__, key), do: GenServer.cast(server, {:close, key})

  @doc """
  What is shown, oldest first: each key, its notice, and whether the
  desktop has it (`shown?`; false while there is no connection).
  """
  @spec list(GenServer.server()) :: [%{key: key(), notice: notice(), shown?: boolean()}]
  def list(server \\ __MODULE__), do: GenServer.call(server, :list)

  @doc "Whether notifications reach the desktop, and through what."
  @spec status(GenServer.server()) :: status()
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @doc "Subscribes the caller to the clicks on `username`'s notifications."
  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(username), do: Phoenix.PubSub.subscribe(MDTClient.PubSub, topic(username))

  @doc false
  def topic(username), do: "desktop:" <> Accounts.id(username)

  # Valid UTF-8 without NUL bytes (the bus drops a connection sending
  # anything else), single-line summaries, and both kept short: GNOME
  # truncates long ones anyway.
  defp clean(notice) do
    %{
      summary: notice.summary |> text() |> String.replace(~r/\s+/, " ") |> cut(@summary_limit),
      body: notice.body |> text() |> cut(@body_limit),
      scope: Map.fetch!(notice, :scope),
      open: Map.fetch!(notice, :open)
    }
  end

  defp text(value) do
    value
    |> to_string()
    |> String.replace_invalid()
    |> String.replace(<<0>>, "")
    |> String.trim()
  end

  defp cut(text, limit) do
    if String.length(text) > limit,
      do: String.slice(text, 0, limit - 1) <> "…",
      else: text
  end

  ## Server

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    config = Application.get_env(:mdt_client, __MODULE__, [])
    address = Keyword.get(opts, :address, Keyword.get(config, :address, :session))

    state = %{
      address: address,
      retry_every: Keyword.get(opts, :retry_every, 30_000),
      conn: nil,
      service: nil,
      status: if(address, do: :connecting, else: :off),
      retry: nil,
      # key => %{notice, owner, id (nil until the desktop has it), at}
      entries: %{},
      ids: %{},
      tokens: %{},
      owners: %{},
      counter: 0
    }

    if address, do: send(self(), :retry)
    {:ok, state}
  end

  @impl true
  def handle_cast({:show, key, notice, owner}, state) do
    previous = Map.get(state.entries, key)

    entry = %{
      notice: notice,
      owner: owner,
      id: previous && previous.id,
      at: (previous && previous.at) || state.counter
    }

    state =
      state
      |> watch(owner)
      |> Map.update!(:counter, &(&1 + 1))
      |> put_in([:entries, key], entry)

    {:noreply, deliver(state, key)}
  end

  def handle_cast({:close, key}, state), do: {:noreply, close_key(state, key)}

  @impl true
  def handle_call(:list, _from, state) do
    list =
      state.entries
      |> Enum.sort_by(fn {_key, entry} -> entry.at end)
      |> Enum.map(fn {key, entry} ->
        %{key: key, notice: entry.notice, shown?: entry.id != nil}
      end)

    {:reply, list, state}
  end

  def handle_call(:status, _from, state), do: {:reply, state.status, state}

  @impl true
  def handle_info(:retry, %{conn: nil} = state), do: {:noreply, connect(%{state | retry: nil})}
  def handle_info(:retry, state), do: {:noreply, ready(%{state | retry: nil}, state.conn)}

  def handle_info({:dbus_signal, conn, %Message{} = signal}, %{conn: conn} = state) do
    if signal.sender == state.service and signal.path == @path and
         signal.interface == @service,
       do: {:noreply, on_signal(state, signal.member, signal.body)},
       else: {:noreply, state}
  end

  def handle_info({:dbus_signal, _old_conn, _signal}, state), do: {:noreply, state}

  # Nobody calls MDT here; a call is answered so the caller doesn't wait.
  def handle_info({:dbus_method_call, conn, call}, state) do
    unless :no_reply_expected in call.flags do
      Connection.send_message(
        conn,
        Message.error(call, "org.freedesktop.DBus.Error.UnknownMethod", "MDT serves nothing here")
      )
    end

    {:noreply, state}
  end

  def handle_info({:EXIT, conn, reason}, %{conn: conn} = state) do
    Logger.info("Desktop notifications lost the session bus: #{inspect(reason)}")

    state = %{
      state
      | conn: nil,
        service: nil,
        status: {:unavailable, "The connection to the session bus closed."},
        entries: Map.new(state.entries, fn {key, entry} -> {key, %{entry | id: nil}} end),
        ids: %{},
        tokens: %{}
    }

    {:noreply, retry(state, 1_000)}
  end

  # A connection that failed to start also exits.
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  def handle_info({:DOWN, _ref, :process, owner, _reason}, state) do
    keys = for {key, %{owner: ^owner}} <- state.entries, do: key
    state = %{state | owners: Map.delete(state.owners, owner)}
    {:noreply, Enum.reduce(keys, state, &close_key(&2, &1))}
  end

  defp close_key(state, key) do
    case Map.pop(state.entries, key) do
      {nil, _entries} ->
        state

      {entry, entries} ->
        if entry.id && state.conn do
          Connection.send_message(state.conn, %{
            Message.call(@service, @path, @service, "CloseNotification", "u", [entry.id])
            | flags: [:no_reply_expected]
          })
        end

        %{state | entries: entries} |> forget_id(entry.id) |> unwatch(entry.owner)
    end
  end

  ## Signals

  defp on_signal(state, "ActivationToken", [id, token]) when is_map_key(state.ids, id),
    do: put_in(state.tokens[id], token)

  defp on_signal(state, "ActionInvoked", [id, _action]) when is_map_key(state.ids, id) do
    key = state.ids[id]
    %{notice: notice} = state.entries[key]

    Phoenix.PubSub.broadcast(
      MDTClient.PubSub,
      topic(notice.scope),
      {:desktop_open, notice.open, state.tokens[id]}
    )

    %{state | tokens: Map.delete(state.tokens, id)}
  end

  # Dismissed, expired, or gone after a click: forgotten either way.
  defp on_signal(state, "NotificationClosed", [id, _reason]) when is_map_key(state.ids, id) do
    {entry, entries} = Map.pop(state.entries, state.ids[id])

    %{state | entries: entries}
    |> forget_id(id)
    |> unwatch(entry.owner)
  end

  defp on_signal(state, _member, _body), do: state

  ## Connection

  defp connect(state) do
    case Connection.start_link(owner: self(), address: state.address) do
      {:ok, conn} -> ready(%{state | conn: conn}, conn)
      {:error, reason} -> retry(%{state | status: {:unavailable, describe(reason)}})
    end
  end

  # Finds the notification service and shows what it doesn't have yet. The
  # connection stays open when there is none: one may start later.
  defp ready(state, conn) do
    case server_information(conn) do
      {:ok, sender, info} ->
        state = %{state | service: sender, status: {:connected, info}}
        state |> pending() |> Enum.reduce(state, &deliver(&2, &1))

      {:error, reason} ->
        retry(%{state | status: {:unavailable, reason}})
    end
  end

  defp server_information(conn) do
    message = Message.call(@service, @path, @service, "GetServerInformation")

    case Connection.call(conn, message) do
      {:ok, %Message{sender: sender, body: [name, vendor, version, _spec]}} ->
        {:ok, sender, %{name: name, vendor: vendor, version: version}}

      {:ok, _other} ->
        {:error, "The notification service answered in a way MDT doesn't understand."}

      {:error, {:dbus, "org.freedesktop.DBus.Error.ServiceUnknown", _text}} ->
        {:error, "No notification service runs on this desktop."}

      {:error, reason} ->
        {:error, describe(reason)}
    end
  end

  # Entries the desktop doesn't have yet, oldest first.
  defp pending(state) do
    state.entries
    |> Enum.filter(fn {_key, entry} -> is_nil(entry.id) end)
    |> Enum.sort_by(fn {_key, entry} -> entry.at end)
    |> Enum.map(&elem(&1, 0))
  end

  defp deliver(%{status: {:connected, _info}, conn: conn} = state, key) when conn != nil do
    entry = state.entries[key]

    case Connection.call(conn, notify(entry)) do
      {:ok, %Message{body: [id]}} ->
        state = if entry.id && entry.id != id, do: forget_id(state, entry.id), else: state

        state
        |> put_in([:entries, key, :id], id)
        |> put_in([:ids, id], key)

      {:error, reason} ->
        Logger.warning("Desktop notification not shown: #{inspect(reason)}")
        retry(%{state | status: {:unavailable, describe(reason)}})
    end
  end

  # Not connected: it goes out once there is a connection.
  defp deliver(state, _key), do: state

  defp notify(%{notice: notice, id: id}) do
    Message.call(@service, @path, @service, "Notify", "susssasa{sv}i", [
      @app_name,
      id || 0,
      "",
      notice.summary,
      escape(notice.body),
      # "default" is a click on the notification itself.
      ["default", "Open", "review", "Review"],
      %{"desktop-entry" => {"s", @desktop_entry}, "urgency" => {"y", 1}},
      -1
    ])
  end

  defp escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp retry(state, after_ms \\ nil) do
    if state.retry, do: Process.cancel_timer(state.retry)
    %{state | retry: Process.send_after(self(), :retry, after_ms || state.retry_every)}
  end

  ## Owners and ids

  defp watch(state, nil), do: state
  defp watch(state, owner) when is_map_key(state.owners, owner), do: state

  defp watch(state, owner),
    do: %{state | owners: Map.put(state.owners, owner, Process.monitor(owner))}

  defp unwatch(state, owner) do
    if Enum.any?(state.entries, fn {_key, entry} -> entry.owner == owner end) do
      state
    else
      case Map.pop(state.owners, owner) do
        {nil, _owners} ->
          state

        {ref, owners} ->
          Process.demonitor(ref, [:flush])
          %{state | owners: owners}
      end
    end
  end

  defp forget_id(state, nil), do: state

  defp forget_id(state, id),
    do: %{state | ids: Map.delete(state.ids, id), tokens: Map.delete(state.tokens, id)}

  defp describe(:no_session_bus), do: "There's no desktop session bus."
  defp describe(:unsupported_address), do: "The session bus address isn't a Unix socket."
  defp describe(:timeout), do: "The desktop didn't answer in time."
  defp describe(:closed), do: "The connection to the session bus closed."
  defp describe({:connect, reason}), do: "Couldn't reach the session bus (#{inspect(reason)})."
  defp describe({:auth, reason}), do: "The session bus refused MDT (#{inspect(reason)})."
  defp describe({:dbus, _name, text}), do: "The notification service refused: #{text}"
  defp describe(other), do: "Couldn't use the session bus: #{inspect(other)}"
end
