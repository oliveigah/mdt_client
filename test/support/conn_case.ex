defmodule MDTClientWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use MDTClientWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint MDTClientWeb.Endpoint

      use MDTClientWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest, except: [build_conn: 0]
      import MDTClientWeb.ConnCase
    end
  end

  setup _tags do
    {:ok, conn: build_conn()}
  end

  @doc """
  A conn on a loopback host, so the suite runs through
  `MDTClientWeb.Plugs.LoopbackHost` rather than around it.
  """
  def build_conn, do: %{Phoenix.ConnTest.build_conn() | host: "127.0.0.1"}

  @doc """
  Creates and unlocks an identity, returning a conn carrying its session.
  """
  def sign_in(conn, username \\ "tester", password \\ "correct horse") do
    {:ok, profile, key} = MDTClient.Accounts.sign_in(username, password)
    :ok = MDTClient.Vault.Store.open(profile.username, key)
    ExUnit.Callbacks.on_exit(fn -> MDTClient.Vault.Store.close(profile.username) end)

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> Plug.Conn.put_session(
        MDTClientWeb.UserAuth.session_key(),
        MDTClientWeb.Session.create(profile.username)
      )

    %{conn: conn, username: profile.username, password: password}
  end
end
