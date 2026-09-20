defmodule MDTClientWeb.UserAuth do
  @moduledoc """
  Session plumbing for LiveViews behind the login screen.

  Real authentication is not built yet, so the hook assigns a scope holding the
  placeholder user from `MDTClient.Accounts`. When the backend lands, only this
  module should need to change.
  """

  import Phoenix.Component, only: [assign_new: 3]

  alias MDTClient.Accounts

  def on_mount(:mock_user, _params, _session, socket) do
    {:cont, assign_new(socket, :current_scope, fn -> %{user: Accounts.mock_user()} end)}
  end
end
