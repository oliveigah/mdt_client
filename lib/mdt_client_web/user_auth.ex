defmodule MDTClientWeb.UserAuth do
  @moduledoc """
  Keeps the tools behind an unlocked vault.

  A mounted LiveView carries the username it signed in as, so one left over
  from an earlier session fails against a closed vault rather than reading
  whoever signed in next.
  """

  use MDTClientWeb, :verified_routes

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [redirect: 2]

  alias MDTClient.Accounts
  alias MDTClient.Vault.Store
  alias MDTClientWeb.Session

  @session_key "mdt_session"

  @doc "The key the session token is stored under."
  def session_key, do: @session_key

  def on_mount(:unlocked, _params, session, socket) do
    with {:ok, %{username: username}} <- Session.fetch(session[@session_key]),
         true <- Store.open?(username) do
      {:cont, assign(socket, :current_scope, %{user: Accounts.profile(username)})}
    else
      _locked -> {:halt, redirect(socket, to: ~p"/")}
    end
  end
end
