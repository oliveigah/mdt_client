defmodule MDTClientWeb.SessionController do
  @moduledoc """
  Signs an identity in and out.

  Unlocking happens here rather than in the LiveView because only a plain
  request can write the session cookie.
  """

  use MDTClientWeb, :controller

  require Logger

  alias MDTClient.Accounts
  alias MDTClient.Preferences
  alias MDTClient.Vault.Store
  alias MDTClientWeb.Session
  alias MDTClientWeb.UserAuth

  def create(conn, %{"user" => %{"username" => username, "password" => password}}) do
    case Accounts.sign_in(username, password) do
      {:ok, profile, key} ->
        :ok = Store.open(profile.username, key)
        :ok = Preferences.put("last_username", profile.username)
        Logger.info("vault unlocked", user: profile.username, system: :auth)

        conn
        |> renew()
        |> put_session(UserAuth.session_key(), Session.create(profile.username))
        |> redirect(to: ~p"/tools")

      {:error, reason} ->
        Logger.warning("sign in failed reason=#{reason}", system: :auth)
        # Reported inline on the form rather than as a toast: it belongs next
        # to the field that caused it, and it should not fade away.
        redirect(conn, to: ~p"/?#{[username: username, error: reason]}")
    end
  end

  def delete(conn, _params) do
    token = get_session(conn, UserAuth.session_key())

    with {:ok, %{username: username}} <- Session.fetch(token) do
      :ok = Store.close(username)
      :ok = Session.delete(token)
      Logger.info("vault locked", user: username, system: :auth)
    end

    conn |> renew() |> redirect(to: ~p"/")
  end

  # A fresh session id on every sign in and out, so a token cannot be fixed
  # in advance.
  defp renew(conn), do: conn |> configure_session(renew: true) |> clear_session()
end
