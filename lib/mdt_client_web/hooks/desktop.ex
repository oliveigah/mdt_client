defmodule MDTClientWeb.Hooks.Desktop do
  @moduledoc """
  Opens what a desktop notification points at when you click it
  (`MDTClient.Desktop.Notifications`), from whichever page is open.

  The window comes forward first: the page asks the desktop shell to present
  it with the activation token the click carried (`mdt:present-window`),
  without which GNOME on Wayland only flags the window. Then it navigates,
  in a second step, so the event reaches the page before it is replaced.
  """

  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1, push_event: 3, push_navigate: 2]

  alias MDTClient.Desktop.Notifications

  def on_mount(:default, _params, _session, socket) do
    if connected?(socket),
      do: Notifications.subscribe(socket.assigns.current_scope.user.username)

    {:cont, attach_hook(socket, :desktop_open, :handle_info, &handle_info/2)}
  end

  defp handle_info({:desktop_open, path, token}, socket) do
    send(self(), {:desktop_navigate, path})
    {:halt, push_event(socket, "mdt:present-window", %{token: token})}
  end

  defp handle_info({:desktop_navigate, path}, socket),
    do: {:halt, push_navigate(socket, to: path)}

  defp handle_info(_message, socket), do: {:cont, socket}
end
