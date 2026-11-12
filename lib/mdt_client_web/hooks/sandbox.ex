defmodule MDTClientWeb.Hooks.Sandbox do
  @moduledoc """
  Keeps the count of approvals and agent requests waiting in every signed in
  page, so the title bar can point at them whichever tool is open.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1]

  alias MDTClient.Sandbox

  def on_mount(:default, _params, _session, socket) do
    username = socket.assigns.current_scope.user.username
    if connected?(socket), do: Sandbox.subscribe_waiting(username)

    {:cont,
     socket
     |> assign(:sandbox_waiting, Sandbox.waiting_count(username))
     |> attach_hook(:sandbox_waiting, :handle_info, &handle_info/2)}
  end

  defp handle_info({:sandbox_waiting, count}, socket),
    do: {:halt, assign(socket, :sandbox_waiting, count)}

  defp handle_info(_message, socket), do: {:cont, socket}
end
