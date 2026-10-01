defmodule MDTClientWeb.Plugs.MCPDiscoveryTest do
  use MDTClientWeb.ConnCase, async: false

  import MDTClient.VaultHelpers

  alias MDTClient.MCP.{Access, Schema}
  alias MDTClient.Diagrams.Library, as: Diagrams
  alias MDTClient.Vault.Store

  setup do
    %{username: username} = unlocked_identity()
    {:ok, token} = Access.issue(username)
    %{token: token, username: username}
  end

  test "creates, reads and paginates using only the advertised examples and contracts", %{
    token: token
  } do
    tools = rpc(token, "tools/list")["result"]["tools"]

    for tool <- tools, example <- tool["inputSchema"]["examples"] do
      assert :ok = Schema.validate(example, tool["inputSchema"])
    end

    for tool <- tools do
      assert is_binary(tool["title"])

      for {_name, property} <- tool["inputSchema"]["properties"] do
        assert is_binary(property["description"])
      end
    end

    families = [
      {"create_note", "get_note", "list_notes"},
      {"create_diagram", "get_diagram", "list_diagrams"},
      {"create_http_request", "get_http_request", "list_http_requests"},
      {"import_http_request", "get_http_request", "list_http_requests"}
    ]

    for {create, get, list} <- families do
      creation = find_tool(tools, create)

      for example <- creation["inputSchema"]["examples"] do
        saved = call(token, creation, example)
        read = call(token, find_tool(tools, get), %{"id" => saved["id"]})
        assert read == saved
        assert saved["url"] =~ saved["path"]

        if create in ["create_http_request", "import_http_request"] do
          assert saved["sent"] == false
          assert saved["request_url"] =~ "https://api.example.test/"
          assert is_map(saved["headers"])
          refute Map.has_key?(saved, "response")
        end
      end

      listing = find_tool(tools, list)
      first = call(token, listing, %{"limit" => 1})
      ids = collect_pages(token, listing, first, [])
      assert length(ids) == first["total"]
      assert Enum.uniq(ids) == ids
      assert call(token, listing, %{"offset" => first["total"]})["items"] == []
    end
  end

  test "discovers guides and validates every JSON example obtained through resources/read", %{
    token: token
  } do
    initialized =
      rpc(token, "initialize", %{
        "protocolVersion" => "2025-11-25",
        "capabilities" => %{},
        "clientInfo" => %{"name" => "discovery-only-agent", "version" => "1"}
      })["result"]

    assert initialized["capabilities"]["resources"] == %{
             "subscribe" => false,
             "listChanged" => false
           }

    assert initialized["instructions"] =~ "resources/read"
    resources = rpc(token, "resources/list")["result"]["resources"]

    assert Enum.map(resources, & &1["uri"]) == [
             "mdt://guides/notes",
             "mdt://guides/diagrams",
             "mdt://guides/http"
           ]

    tools = rpc(token, "tools/list")["result"]["tools"]

    for resource <- resources do
      assert [%{"uri" => uri, "mimeType" => "text/markdown", "text" => text}] =
               rpc(token, "resources/read", %{"uri" => resource["uri"]})["result"]["contents"]

      assert uri == resource["uri"]

      examples = Regex.scan(~r/### (\w+)\s+```json\n(.*?)\n```/s, text)
      assert length(examples) >= 2

      for [_, name, json] <- examples do
        assert :ok = Schema.validate(Jason.decode!(json), find_tool(tools, name)["inputSchema"])
      end
    end

    assert rpc(token, "resources/templates/list")["result"] == %{"resourceTemplates" => []}
  end

  test "guides accept only published URIs and remain authenticated", %{
    token: token,
    username: username
  } do
    for uri <- ["mdt://guides/missing", "file:///etc/passwd", "mdt://guides/../notes"] do
      assert rpc(token, "resources/read", %{"uri" => uri})["error"]["code"] == -32002
    end

    assert rpc(token, "resources/read", %{})["error"]["code"] == -32602
    assert rpc(token, "resources/read", %{"uri" => 123})["error"]["code"] == -32602
    assert rpc(token, "resources/list", %{"cursor" => "invalid"})["error"]["code"] == -32602

    :ok = Store.close(username)
    assert rpc(token, "resources/read", %{"uri" => "mdt://guides/notes"}, 401)["error"]
  end

  test "diagram schema rejects missing coordinates and row endpoints before saving", %{
    token: token,
    username: username
  } do
    tool = find_tool(rpc(token, "tools/list")["result"]["tools"], "create_diagram")
    example = hd(tool["inputSchema"]["examples"])
    [shape, api, arrow] = example["elements"]

    cases = [
      {[Map.delete(shape, "width")], "arguments.elements[0].width is required"},
      {[Map.put(shape, "height", 0)], "arguments.elements[0].height must be greater than 0"},
      {[shape, api, Map.delete(arrow, "y2")], "arguments.elements[2].y2 is required"},
      {[Map.put(arrow, "startRow", "id") |> Map.delete("start")],
       "arguments.elements[0].start is required"},
      {[Map.put(arrow, "startRow", "id") |> Map.put("start", nil)],
       "arguments.elements[0].start must have type"}
    ]

    for {elements, message} <- cases do
      args = Map.put(example, "elements", elements)
      assert {:error, reason} = Schema.validate(args, tool["inputSchema"])
      assert reason =~ message
      result = rpc(token, "tools/call", %{"name" => tool["name"], "arguments" => args})["result"]
      assert result["isError"] == true
      assert hd(result["content"])["text"] =~ message
    end

    assert Diagrams.list(username) == []
  end

  test "attachment errors identify the offending field and missing target", %{token: token} do
    tool = find_tool(rpc(token, "tools/list")["result"]["tools"], "create_diagram")
    example = List.last(tool["inputSchema"]["examples"])
    [customers, orders, arrow] = example["elements"]

    for {changes, field, target} <- [
          {%{"end" => "missing_table"}, "end", "missing_table"},
          {%{"endRow" => "missing_row"}, "endRow", "missing_row"}
        ] do
      args = Map.put(example, "elements", [customers, orders, Map.merge(arrow, changes)])
      result = rpc(token, "tools/call", %{"name" => tool["name"], "arguments" => args})["result"]
      assert result["isError"] == true
      assert hd(result["content"])["text"] =~ "arguments.elements[2].#{field}"
      assert hd(result["content"])["text"] =~ target
    end
  end

  defp collect_pages(token, tool, page, ids) do
    ids = ids ++ Enum.map(page["items"], & &1["id"])

    if page["next_offset"] == nil do
      ids
    else
      next = call(token, tool, %{"limit" => 1, "offset" => page["next_offset"]})
      collect_pages(token, tool, next, ids)
    end
  end

  defp call(token, tool, args) do
    result = rpc(token, "tools/call", %{"name" => tool["name"], "arguments" => args})["result"]
    assert result["isError"] == false, inspect(result)
    data = result["structuredContent"]
    assert :ok = Schema.validate(data, tool["outputSchema"])
    assert Jason.decode!(hd(result["content"])["text"]) == data
    data
  end

  defp find_tool(tools, name), do: Enum.find(tools, &(&1["name"] == name))

  defp rpc(token, method, params \\ %{}, status \\ 200) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json, text/event-stream")
    |> put_req_header("authorization", "Bearer " <> token)
    |> post(
      "/mcp",
      Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params})
    )
    |> json_response(status)
  end
end
