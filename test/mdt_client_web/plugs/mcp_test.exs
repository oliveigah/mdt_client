defmodule MDTClientWeb.Plugs.MCPTest do
  use MDTClientWeb.ConnCase, async: false

  import MDTClient.VaultHelpers
  alias MDTClient.MCP.Access
  alias MDTClient.Notes.Library
  alias MDTClient.Vault.Store

  setup do
    %{username: username, key: key} = unlocked_identity()
    {:ok, token} = Access.issue(username)
    %{token: token, username: username, key: key}
  end

  test "initializes and discovers the tools", %{token: token} do
    message = %{
      "jsonrpc" => "2.0",
      "id" => "init",
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => "2025-11-25",
        "capabilities" => %{},
        "clientInfo" => %{"name" => "test-agent", "version" => "1"}
      }
    }

    initialized = rpc(token, message) |> json_response(200)
    assert initialized["id"] == "init"
    assert initialized["result"]["protocolVersion"] == "2025-11-25"
    assert initialized["result"]["capabilities"]["tools"] == %{"listChanged" => false}

    tools = rpc(token, request("tools/list")) |> json_response(200)
    names = Enum.map(tools["result"]["tools"], & &1["name"])
    assert "create_note" in names
    assert "create_diagram" in names
    assert "create_http_request" in names
    assert "import_http_request" in names
    assert length(names) == 10
  end

  test "accepts notifications without a body and never executes a notification as a tool", %{
    token: token,
    username: username
  } do
    conn = rpc(token, %{"jsonrpc" => "2.0", "method" => "notifications/initialized"})
    assert response(conn, 202) == ""

    conn =
      rpc(token, %{
        "jsonrpc" => "2.0",
        "method" => "tools/call",
        "params" => %{
          "name" => "create_note",
          "arguments" => %{"title" => "Ignored", "body" => "Ignored"}
        }
      })

    assert response(conn, 202) == ""
    assert Library.list(username) == []
  end

  test "requires a current agent token even with a signed in browser session", %{conn: conn} do
    %{conn: signed_in} = sign_in(conn, "browser")
    conn = signed_in |> headers() |> post("/mcp", Jason.encode!(request("tools/list")))
    assert json_response(conn, 401)["error"]
    assert get_resp_header(conn, "www-authenticate") == ["Bearer realm=\"MDT\""]
  end

  test "the same configured token works again after unlocking", %{
    token: token,
    username: username,
    key: key
  } do
    assert rpc(token, request("ping")) |> json_response(200)
    :ok = Store.close(username)
    assert rpc(token, request("ping")) |> json_response(401)
    :ok = Store.open(username, key)
    assert rpc(token, request("ping")) |> json_response(200)
    :ok = Access.revoke(username)
    :ok = Store.close(username)
    :ok = Store.open(username, key)
    assert rpc(token, request("ping")) |> json_response(401)
  end

  test "checks local Host, Origin and peer address", %{token: token} do
    for conn <- [
          %{build_conn() | host: "evil.test"},
          put_req_header(build_conn(), "origin", "https://evil.test"),
          put_req_header(build_conn(), "origin", "null"),
          put_req_header(build_conn(), "origin", "http://127.0.0.1:9999"),
          %{build_conn() | remote_ip: {10, 0, 0, 2}}
        ] do
      assert rpc(token, request("ping"), conn) |> json_response(403)
    end

    conn = build_conn()
    origin = "#{conn.scheme}://#{conn.host}"

    assert rpc(token, request("ping"), put_req_header(conn, "origin", origin))
           |> json_response(200)
  end

  test "rejects wrong protocol, content type, accept header and oversized bodies", %{token: token} do
    conn = build_conn() |> put_req_header("mcp-protocol-version", "1900-01-01")
    assert rpc(token, request("ping"), conn) |> json_response(400)

    conn = build_conn() |> put_req_header("authorization", "Bearer " <> token)

    assert conn
           |> put_req_header("content-type", "text/plain")
           |> post("/mcp", "{}")
           |> json_response(415)

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "text/html")

    assert conn |> post("/mcp", "{}") |> json_response(406)

    oversized = String.duplicate("x", 2_000_001)
    conn = build_conn() |> headers() |> put_req_header("authorization", "Bearer " <> token)
    assert conn |> post("/mcp", oversized) |> json_response(413)
  end

  test "returns protocol errors and tool errors in their distinct forms", %{
    token: token,
    username: username
  } do
    conn = build_conn() |> headers() |> put_req_header("authorization", "Bearer " <> token)
    assert conn |> post("/mcp", "{") |> json_response(400) |> get_in(["error", "code"]) == -32700

    assert rpc(token, request("unknown")) |> json_response(200) |> get_in(["error", "code"]) ==
             -32601

    assert rpc(token, request("tools/call", %{"name" => "unknown"}))
           |> json_response(200)
           |> get_in(["error", "code"]) == -32602

    result =
      rpc(
        token,
        request("tools/call", %{
          "name" => "create_note",
          "arguments" => %{"title" => "Oops", "body" => 123}
        })
      )
      |> json_response(200)

    assert result["result"]["isError"]
    refute Map.has_key?(result, "error")
    assert Library.list(username) == []
  end

  test "has no SSE stream or session deletion and does not cache credentials", %{token: token} do
    for method <- [:get, :delete] do
      conn = build_conn() |> put_req_header("authorization", "Bearer " <> token)
      conn = Phoenix.ConnTest.dispatch(conn, @endpoint, method, "/mcp", nil)
      assert response(conn, 405) == ""
      assert get_resp_header(conn, "allow") == ["POST"]
      assert get_resp_header(conn, "cache-control") == ["no-store"]
    end
  end

  defp request(method, params \\ %{}),
    do: %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params}

  defp rpc(token, message, conn \\ build_conn()) do
    conn
    |> headers()
    |> put_req_header("authorization", "Bearer " <> token)
    |> post("/mcp", Jason.encode!(message))
  end

  defp headers(conn),
    do:
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")
end
