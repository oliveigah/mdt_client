defmodule MDTClientWeb.Plugs.LoopbackHostTest do
  use MDTClientWeb.ConnCase

  alias MDTClient.Accounts
  alias MDTClient.VaultHelpers

  setup do
    VaultHelpers.reset_data_dir!()
    on_exit(&VaultHelpers.reset_data_dir!/0)
    :ok
  end

  for host <- ~w(127.0.0.1 localhost) do
    test "#{host} is served", %{conn: conn} do
      conn = %{conn | host: unquote(host)}

      assert conn |> get(~p"/") |> html_response(200)
    end
  end

  test "a rebound host is refused", %{conn: conn} do
    conn = %{conn | host: "attacker.test"}

    assert conn |> get(~p"/") |> response(403)
  end

  test "sign in cannot be driven from a rebound host", %{conn: conn} do
    conn = %{conn | host: "attacker.test"}

    assert conn
           |> post(~p"/login", %{"user" => %{"username" => "victim", "password" => "guess"}})
           |> response(403)

    refute Accounts.exists?("victim")
  end

  test "the rule is lifted when the endpoint is bound publicly", %{conn: conn} do
    Application.put_env(:mdt_client, :require_loopback_host, false)
    on_exit(fn -> Application.put_env(:mdt_client, :require_loopback_host, true) end)

    conn = %{conn | host: "mdt.example.com"}

    assert conn |> get(~p"/") |> html_response(200)
  end
end
