defmodule MDTClientWeb.Notices do
  @moduledoc """
  App wide notices: short messages any tool raises about work it finished or
  could not do, floating in the bottom left corner of the window.

  Mounted on every signed in LiveView, which keeps them in the `:notices`
  assign and hands them to `<Layouts.app notices={@notices}>`. Dismissing is
  handled here as well, so a tool only ever calls `put_notice/4`.

  Errors and warnings stay until they are dismissed. Successes and infos leave
  on their own after a few seconds on screen, see the `NoticeTimer` hook.
  """

  import Phoenix.Component, only: [assign: 3, update: 3]
  import Phoenix.LiveView, only: [attach_hook: 4]

  @kinds [:success, :info, :warning, :error]

  def on_mount(:default, _params, _session, socket) do
    {:cont,
     socket
     |> assign(:notices, [])
     |> attach_hook(:notices, :handle_event, &handle/3)}
  end

  @doc """
  Adds a notice of the given kind, one of `#{inspect(@kinds)}`.

  ## Options

    * `:body` - details shown under the title, such as command output
    * `:source` - what the notice is about, such as a repository name

  """
  def put_notice(socket, kind, title, opts \\ []) when kind in @kinds do
    notice = %{
      id: Integer.to_string(System.unique_integer([:positive])),
      kind: kind,
      title: title,
      body: opts[:body],
      source: opts[:source]
    }

    update(socket, :notices, &(&1 ++ [notice]))
  end

  @doc "Whether a notice waits to be dismissed rather than leaving on its own."
  def persistent?(%{kind: kind}), do: kind in [:warning, :error]

  defp handle("dismiss_notice", %{"id" => id}, socket) do
    {:halt, update(socket, :notices, &Enum.reject(&1, fn notice -> notice.id == id end))}
  end

  defp handle(_event, _params, socket), do: {:cont, socket}
end
