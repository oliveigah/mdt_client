defmodule MDTClient.FakeNotificationService do
  @moduledoc false
  # org.freedesktop.Notifications on a test bus, behaving as GNOME Shell's
  # does where MDT depends on it: ids count from 1, a replaced notification
  # keeps its id, and every signal goes only to the connection that showed
  # the notification. The test process hears of every Notify
  # (`{:notified, id, notify}`) and CloseNotification (`{:closed, id}`), and
  # plays the user with click/3 and dismiss/2.

  use GenServer

  alias MDTClient.DBus.{Connection, Message}

  @service "org.freedesktop.Notifications"
  @path "/org/freedesktop/Notifications"

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "A click on the notification: its token, the action, then GNOME closing it."
  def click(fake, id, token \\ "token-for-the-click"),
    do: GenServer.call(fake, {:click, id, token})

  @doc "The user closing it."
  def dismiss(fake, id), do: GenServer.call(fake, {:dismiss, id})

  @impl true
  def init(opts) do
    {:ok, conn} = Connection.start_link(address: Keyword.fetch!(opts, :address))

    {:ok, %Message{body: [1]}} =
      Connection.call(
        conn,
        Message.call(
          "org.freedesktop.DBus",
          "/org/freedesktop/DBus",
          "org.freedesktop.DBus",
          "RequestName",
          "su",
          [@service, 4]
        )
      )

    {:ok, %{conn: conn, test: Keyword.fetch!(opts, :test), next: 1, shown: %{}}}
  end

  @impl true
  def handle_call({:click, id, token}, _from, state) do
    %{sender: sender} = state.shown[id]
    signal(state, sender, "ActivationToken", "us", [id, token])
    signal(state, sender, "ActionInvoked", "us", [id, "default"])
    signal(state, sender, "NotificationClosed", "uu", [id, 2])
    {:reply, :ok, %{state | shown: Map.delete(state.shown, id)}}
  end

  def handle_call({:dismiss, id}, _from, state) do
    %{sender: sender} = state.shown[id]
    signal(state, sender, "NotificationClosed", "uu", [id, 2])
    {:reply, :ok, %{state | shown: Map.delete(state.shown, id)}}
  end

  @impl true
  def handle_info(
        {:dbus_method_call, conn, %Message{member: "GetServerInformation"} = call},
        state
      ) do
    Connection.send_message(
      conn,
      Message.reply(call, "ssss", ["fake-shell", "MDT tests", "50.0", "1.2"])
    )

    {:noreply, state}
  end

  def handle_info({:dbus_method_call, conn, %Message{member: "Notify"} = call}, state) do
    [app_name, replaces, icon, summary, body, actions, hints, timeout] = call.body
    {id, state} = if is_map_key(state.shown, replaces), do: {replaces, state}, else: next(state)

    notify = %{
      app_name: app_name,
      replaces: replaces,
      icon: icon,
      summary: summary,
      body: body,
      actions: actions,
      hints: Map.new(hints),
      timeout: timeout,
      sender: call.sender
    }

    Connection.send_message(conn, Message.reply(call, "u", [id]))
    send(state.test, {:notified, id, notify})
    {:noreply, put_in(state.shown[id], notify)}
  end

  def handle_info({:dbus_method_call, conn, %Message{member: "CloseNotification"} = call}, state) do
    [id] = call.body

    if :no_reply_expected not in call.flags,
      do: Connection.send_message(conn, Message.reply(call))

    case Map.pop(state.shown, id) do
      {nil, _shown} ->
        {:noreply, state}

      {%{sender: sender}, shown} ->
        signal(state, sender, "NotificationClosed", "uu", [id, 3])
        send(state.test, {:closed, id})
        {:noreply, %{state | shown: shown}}
    end
  end

  def handle_info({:dbus_signal, _conn, _signal}, state), do: {:noreply, state}

  defp next(state), do: {state.next, %{state | next: state.next + 1}}

  defp signal(state, destination, member, signature, body) do
    Connection.send_message(state.conn, %Message{
      type: :signal,
      path: @path,
      interface: @service,
      member: member,
      destination: destination,
      signature: signature,
      body: body
    })
  end
end
