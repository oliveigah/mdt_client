defmodule MDTClientWeb.Hooks.Updates do
  @moduledoc "Shows the desktop update state across public and signed in views."

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1, push_event: 3]

  alias MDTClient.Updates

  def on_mount(:default, _params, _session, socket) do
    if connected?(socket), do: Updates.subscribe()

    update = Updates.current()

    socket =
      if connected?(socket) and update.status == :installed do
        push_event(socket, "update-installed", %{})
      else
        socket
      end

    {:cont,
     socket
     |> assign(:update, update)
     |> attach_hook(:mdt_updates, :handle_info, &handle_info/2)
     |> attach_hook(:mdt_update_install, :handle_event, &handle_event/3)}
  end

  defp handle_info({:mdt_update, update}, socket) do
    socket = assign(socket, :update, update)

    socket =
      if update.status == :installed do
        push_event(socket, "update-installed", %{})
      else
        socket
      end

    {:halt, socket}
  end

  defp handle_info(_message, socket), do: {:cont, socket}

  defp handle_event("check_updates", _params, socket) do
    _ = Updates.check()
    {:halt, socket}
  end

  defp handle_event("install_update", _params, socket) do
    _ = Updates.install()
    {:halt, socket}
  end

  defp handle_event("dismiss_update", _params, socket) do
    :ok = Updates.dismiss()
    {:halt, socket}
  end

  defp handle_event(_event, _params, socket), do: {:cont, socket}
end
