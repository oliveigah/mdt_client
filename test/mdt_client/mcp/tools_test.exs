defmodule MDTClient.MCP.ToolsTest do
  use ExUnit.Case, async: true

  import MDTClient.VaultHelpers
  alias MDTClient.MCP.Tools
  alias MDTClient.HttpClient.{Resources, Transfer, Translation}
  alias MDTClient.Notes.Library, as: Notes
  alias MDTClient.Diagrams.Library, as: Diagrams
  alias MDTClient.Vault.Store

  setup do
    unlocked_identity()
  end

  test "saves, finds and reads Markdown notes only in the authorized identity", %{
    username: username
  } do
    other = also_unlock("other")

    note =
      call(
        "create_note",
        %{"title" => "Launch idea", "body" => "# Ship\nAdd an MCP interface"},
        username
      )

    assert note["body"] == "# Ship\nAdd an MCP interface"
    assert note["url"] == "http://127.0.0.1:12995/tools/notes?id=#{note["id"]}"
    assert {:ok, stored} = Notes.get(username, note["id"])
    assert stored.title == "Launch idea"
    assert call("get_note", %{"id" => note["id"]}, username) == note
    assert [%{"id" => id}] = call("list_notes", %{"query" => "MCP launch"}, username)["items"]
    assert id == note["id"]
    assert call("list_notes", %{}, other)["items"] == []
    assert tool_error?("get_note", %{"id" => note["id"]}, other)
  end

  test "creates native editable diagrams with attached arrows and typed table rows", %{
    username: username
  } do
    table = %{
      "id" => "users",
      "type" => "table",
      "text" => "Users",
      "x" => 40,
      "y" => 40,
      "width" => 240,
      "height" => 120,
      "rows" => [%{"id" => "user_id", "type" => "uuid", "name" => "id"}]
    }

    shape = %{
      "id" => "api",
      "type" => "rectangle",
      "text" => "API",
      "x" => 400,
      "y" => 40,
      "width" => 180,
      "height" => 80
    }

    arrow = %{
      "id" => "relation",
      "type" => "arrow",
      "x1" => 280,
      "y1" => 80,
      "x2" => 400,
      "y2" => 80,
      "start" => "users",
      "startRow" => "user_id",
      "end" => "api"
    }

    diagram =
      call(
        "create_diagram",
        %{"title" => "Architecture", "elements" => [table, shape, arrow]},
        username
      )

    assert {:ok, stored} = Diagrams.get(username, diagram["id"])
    assert length(stored.elements) == 3
    assert List.last(stored.elements)["startRow"] == "user_id"
    assert call("get_diagram", %{"id" => diagram["id"]}, username) == diagram
    assert length(call("list_diagrams", %{"query" => "uuid API"}, username)["items"]) == 1
  end

  test "rejects diagrams that would lose elements or attachments", %{username: username} do
    shape = %{
      "id" => "a",
      "type" => "rectangle",
      "x" => 0,
      "y" => 0,
      "width" => 100,
      "height" => 60
    }

    arrow = %{
      "id" => "arrow",
      "type" => "arrow",
      "x1" => 0,
      "y1" => 0,
      "x2" => 100,
      "y2" => 60,
      "end" => "missing"
    }

    for elements <- [
          [shape, shape],
          [arrow],
          [Map.delete(shape, "width")],
          [Map.put(shape, "id", "a\n")],
          [Map.put(shape, "width", 0)],
          [Map.put(shape, "type", "mermaid")]
        ] do
      assert tool_error?(
               "create_diagram",
               %{"title" => "Invalid", "elements" => elements},
               username
             )
    end

    assert Diagrams.list(username) == []
  end

  test "stores HTTP samples without a response, and keeps them through encryption and export", %{
    username: username,
    key: key
  } do
    args = %{
      "url" => "http://127.0.0.1:1/orders",
      "method" => "POST",
      "description" => "Order sample",
      "tags" => ["orders"],
      "headers" => [
        %{"name" => "Content-Type", "value" => "application/json"},
        %{"name" => "X-Demo", "value" => "sample"}
      ],
      "body" => ~s({"sku":"A"})
    }

    sample = call("create_http_request", args, username)
    refute sample["sent"]
    assert {:ok, entry = {_id, _metadata, request, nil}} = Resources.get(username, sample["id"])
    assert request.body == args["body"]
    assert request.method == :post
    assert Translation.request_from_history(entry).response == nil
    {:ok, outline} = Resources.outline(username, sample["id"])
    assert Translation.request_outline_from_history(outline).response == nil
    assert call("get_http_request", %{"id" => sample["id"]}, username) == sample

    assert [%{"sent" => false}] =
             call("list_http_requests", %{"query" => "Order sample"}, username)["items"]

    {:ok, section} = Transfer.export(username)
    assert {:ok, [_entry]} = Transfer.prepare(1, section)

    :ok = Store.close(username)

    refute File.read!(MDTClient.Accounts.store_path(username, "http_history.bin")) =~
             "Order sample"

    :ok = Store.open(username, key)
    assert call("get_http_request", %{"id" => sample["id"]}, username) == sample
  end

  test "imports curl by parsing it, preserving method, headers and body", %{username: username} do
    sample =
      call(
        "import_http_request",
        %{
          "curl" => "curl -X POST https://example.test/notes -H 'X-Demo: sample' -d 'hello'",
          "description" => "Curl sample"
        },
        username
      )

    assert sample["method"] == "POST"
    assert sample["headers"]["x-demo"] == ["sample"]
    assert sample["body"] == "hello"
    refute sample["sent"]
    assert tool_error?("import_http_request", %{"curl" => "echo nope"}, username)
    assert tool_error?("create_http_request", %{"url" => "file:///etc/passwd"}, username)
  end

  test "validates sizes, types and unknown fields before writing, and paginates lists", %{
    username: username
  } do
    assert tool_error?(
             "create_note",
             %{"title" => "Too large", "body" => String.duplicate("x", 100_001)},
             username
           )

    assert tool_error?(
             "create_note",
             %{"title" => "Spoof", "body" => "Text", "username" => "other"},
             username
           )

    assert Notes.list(username) == []

    for title <- ["First", "Second", "Third"],
        do: call("create_note", %{"title" => title, "body" => ""}, username)

    first = call("list_notes", %{"limit" => 2}, username)
    assert length(first["items"]) == 2
    assert first["total"] == 3
    assert first["next_offset"] == 2
    last = call("list_notes", %{"offset" => 2, "limit" => 2}, username)
    assert length(last["items"]) == 1
    assert last["next_offset"] == nil
    assert tool_error?("list_notes", %{"limit" => 0}, username)
  end

  defp call(name, args, username) do
    {:ok, result} = Tools.call(name, args, username, "http://127.0.0.1:12995")
    refute result["isError"], inspect(result)
    Jason.decode!(Jason.encode!(result["structuredContent"]))
  end

  defp tool_error?(name, args, username) do
    {:ok, result} = Tools.call(name, args, username, "http://127.0.0.1:12995")
    result["isError"]
  end
end
