defmodule MDTClientWeb.Hooks.Theme do
  @moduledoc """
  Persists the theme toggle into `MDTClient.Preferences`.

  The pre-paint script in the root layout still owns *applying* the theme,
  since only the browser knows what "system" resolves to. This remembers the
  choice so it survives local storage being cleared.
  """

  import Phoenix.LiveView, only: [attach_hook: 4]

  alias MDTClient.Preferences

  @themes ~w(system light dark)

  def on_mount(:default, _params, _session, socket) do
    {:cont, attach_hook(socket, :set_theme, :handle_event, &handle/3)}
  end

  defp handle("set_theme", %{"theme" => theme}, socket) when theme in @themes do
    :ok = Preferences.put("theme", theme)
    {:halt, socket}
  end

  defp handle(_event, _params, socket), do: {:cont, socket}
end
