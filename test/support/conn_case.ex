defmodule MDTClientWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  `sign_in/3` gives each test a unique identity and cleans up its stores,
  files and session on exit, so identity-scoped tests can run with
  `async: true`. Tests that change application-wide preferences,
  configuration, update state or shared HTTP mocks must remain synchronous.
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
  Creates and unlocks a unique identity, returning a conn carrying its session.
  """
  def sign_in(conn, username \\ "tester", password \\ "correct horse") do
    %{username: username} = MDTClient.VaultHelpers.unlocked_identity(username, password)
    token = MDTClientWeb.Session.create(username)
    ExUnit.Callbacks.on_exit(fn -> MDTClientWeb.Session.delete(token) end)

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> Plug.Conn.put_session(
        MDTClientWeb.UserAuth.session_key(),
        token
      )

    %{conn: conn, username: username, password: password}
  end
end
