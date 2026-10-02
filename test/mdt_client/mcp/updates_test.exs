defmodule MDTClient.MCP.UpdatesTest do
  use ExUnit.Case, async: true

  import MDTClient.VaultHelpers

  alias MDTClient.Accounts
  alias MDTClient.Diagrams.Library, as: Diagrams
  alias MDTClient.HttpClient.Resources
  alias MDTClient.MCP.Tools
  alias MDTClient.Notes.Library, as: Notes
  alias MDTClient.Vault.Store

  setup do
    unlocked_identity()
  end

  test "updates note fields independently, preserving identity and completion", %{
    username: username
  } do
    note = call("create_note", %{"title" => "Original", "body" => "Keep this body"}, username)
    {:ok, done} = Notes.set_done(username, note["id"], true)

    renamed = call("update_note", %{"id" => note["id"], "title" => "Renamed"}, username)
    assert renamed["id"] == note["id"]
    assert renamed["title"] == "Renamed"
    assert renamed["body"] == note["body"]
    assert renamed["created_at"] == note["created_at"]
    assert renamed["url"] == note["url"]
    assert renamed["done"]

    args = %{"id" => note["id"], "body" => "## Updated\n- [x] Ship"}
    updated = call("update_note", args, username)
    assert updated["body"] == args["body"]
    assert updated["title"] == "Renamed"
    assert call("get_note", %{"id" => note["id"]}, username) == updated
    assert call("update_note", args, username) == updated
    assert {:ok, stored} = Notes.get(username, note["id"])
    assert stored.done_at == done.done_at

    assert [%{"id" => id}] =
             call("list_notes", %{"query" => "Updated Renamed"}, username)["items"]

    assert id == note["id"]

    cleared = call("update_note", %{"id" => note["id"], "body" => ""}, username)
    assert cleared["body"] == ""
    assert cleared["title"] == "Renamed"
    assert cleared["done"]
  end

  test "updates diagram fields independently and replaces the complete canvas", %{
    username: username
  } do
    diagram =
      call(
        "create_diagram",
        %{"title" => "Original", "elements" => [box("old", "Old")]},
        username
      )

    renamed = call("update_diagram", %{"id" => diagram["id"], "title" => "Renamed"}, username)
    assert renamed["elements"] == diagram["elements"]
    assert renamed["created_at"] == diagram["created_at"]
    assert renamed["url"] == diagram["url"]

    args = %{"id" => diagram["id"], "elements" => [box("new", "Replacement")]}
    updated = call("update_diagram", args, username)
    assert updated["id"] == diagram["id"]
    assert updated["title"] == "Renamed"
    assert [%{"id" => "new", "text" => "Replacement"}] = updated["elements"]
    assert call("get_diagram", %{"id" => diagram["id"]}, username) == updated
    assert call("update_diagram", args, username) == updated

    assert [%{"id" => id}] =
             call("list_diagrams", %{"query" => "Replacement Renamed"}, username)["items"]

    assert id == diagram["id"]
    cleared = call("update_diagram", %{"id" => diagram["id"], "elements" => []}, username)
    assert cleared["elements"] == []
    assert cleared["title"] == "Renamed"
  end

  test "updates refuse missing or foreign IDs without creating an item", %{username: username} do
    other = also_unlock("other")
    note = call("create_note", %{"title" => "Private", "body" => "Private body"}, username)
    diagram = call("create_diagram", %{"title" => "Private", "elements" => []}, username)

    for {tool, get, item} <- [
          {"update_note", "get_note", note},
          {"update_diagram", "get_diagram", diagram}
        ] do
      assert error(tool, %{"id" => "missing_id", "title" => "Changed"}, username) =~ "not found"
      assert error(tool, %{"id" => item["id"], "title" => "Changed"}, other) =~ "not found"
      assert call(get, %{"id" => item["id"]}, username) == item
    end

    assert length(Notes.list(username)) == 1
    assert length(Diagrams.list(username)) == 1
    assert Notes.list(other) == []
    assert Diagrams.list(other) == []

    # Updates check existence inside the library process, so they cannot
    # recreate an item deleted between an MCP read and a write.
    :ok = Notes.delete(username, note["id"])
    :ok = Diagrams.delete(username, diagram["id"])
    assert Notes.update(username, note["id"], %{title: "Changed"}) == :error
    assert Diagrams.update(username, diagram["id"], %{title: "Changed"}) == :error
    assert Notes.list(username) == []
    assert Diagrams.list(username) == []
  end

  test "validates all update arguments before changing either library", %{username: username} do
    note = call("create_note", %{"title" => "Original", "body" => "Body"}, username)
    diagram = call("create_diagram", %{"title" => "Original", "elements" => []}, username)

    for {tool, get, item} <- [
          {"update_note", "get_note", note},
          {"update_diagram", "get_diagram", diagram}
        ] do
      for args <- [
            %{"id" => item["id"]},
            %{"title" => "Changed"},
            %{"id" => "../../etc", "title" => "Changed"},
            %{"id" => item["id"], "title" => nil},
            %{"id" => item["id"], "title" => String.duplicate("x", 201)},
            %{"id" => item["id"], "title" => "Changed", "username" => "other"}
          ] do
        assert is_binary(error(tool, args, username))
        assert call(get, %{"id" => item["id"]}, username) == item
      end
    end

    for body <- [nil, 123, String.duplicate("x", 100_001)] do
      assert is_binary(error("update_note", %{"id" => note["id"], "body" => body}, username))
    end

    assert call("get_note", %{"id" => note["id"]}, username) == note
  end

  test "invalid replacement elements and attachments leave the whole diagram unchanged", %{
    username: username
  } do
    shape = box("a", "Keep")
    diagram = call("create_diagram", %{"title" => "Original", "elements" => [shape]}, username)

    arrow = %{
      "id" => "arrow",
      "type" => "arrow",
      "x1" => 0,
      "y1" => 0,
      "x2" => 100,
      "y2" => 60,
      "start" => "a",
      "end" => "missing"
    }

    table =
      Map.merge(shape, %{
        "type" => "table",
        "rows" => [%{"id" => "row", "type" => "uuid", "name" => "id"}]
      })

    for elements <- [
          nil,
          [shape, shape],
          [Map.delete(shape, "width")],
          [Map.put(shape, "width", 0)],
          [Map.put(shape, "type", "mermaid")],
          [shape, arrow],
          [table, arrow |> Map.put("end", "a") |> Map.put("endRow", "missing_row")],
          [table, arrow |> Map.put("end", "a") |> Map.put("startRow", "missing_row")],
          [Map.put(table, "rows", table["rows"] ++ table["rows"])]
        ] do
      assert is_binary(
               error(
                 "update_diagram",
                 %{"id" => diagram["id"], "title" => "Changed", "elements" => elements},
                 username
               )
             )

      assert call("get_diagram", %{"id" => diagram["id"]}, username) == diagram
    end
  end

  test "updates survive vault close and reopen through encrypted storage", %{
    username: username,
    key: key
  } do
    note = call("create_note", %{"title" => "Note", "body" => "Old body"}, username)
    diagram = call("create_diagram", %{"title" => "Diagram", "elements" => []}, username)

    note =
      call(
        "update_note",
        %{"id" => note["id"], "title" => "Updated note", "body" => "Secret update"},
        username
      )

    diagram =
      call(
        "update_diagram",
        %{
          "id" => diagram["id"],
          "title" => "Updated diagram",
          "elements" => [box("secret", "Secret update")]
        },
        username
      )

    :ok = Store.close(username)

    for file <- ["notes.bin", "diagrams.bin"] do
      refute File.read!(Accounts.store_path(username, file)) =~ "Secret update"
    end

    :ok = Store.open(username, key)
    assert call("get_note", %{"id" => note["id"]}, username) == note
    assert call("get_diagram", %{"id" => diagram["id"]}, username) == diagram
  end

  test "HTTP create and import always append and reject an existing ID", %{username: username} do
    args = %{
      "url" => "https://example.test/sample",
      "description" => "Original",
      "body" => "Body"
    }

    original = call("create_http_request", args, username)
    repeated = call("create_http_request", args, username)
    refute original["id"] == repeated["id"]

    curl = %{"curl" => "curl https://example.test/sample", "description" => "Imported"}
    imported = call("import_http_request", curl, username)
    imported_again = call("import_http_request", curl, username)
    refute imported["id"] == imported_again["id"]

    assert error("create_http_request", Map.put(args, "id", original["id"]), username) =~
             "id is not supported"

    assert error("import_http_request", Map.put(curl, "id", original["id"]), username) =~
             "id is not supported"

    assert {:error, :unknown_tool} =
             Tools.call(
               "update_http_request",
               %{"id" => original["id"]},
               username,
               "http://localhost"
             )

    assert length(Resources.summaries(username)) == 4

    for sample <- [original, repeated, imported, imported_again] do
      refute sample["sent"]
      assert call("get_http_request", %{"id" => sample["id"]}, username) == sample
    end
  end

  defp box(id, text) do
    %{
      "id" => id,
      "type" => "rectangle",
      "x" => 0,
      "y" => 0,
      "width" => 120,
      "height" => 60,
      "text" => text
    }
  end

  defp call(name, args, username) do
    {:ok, result} = Tools.call(name, args, username, "http://127.0.0.1:12995")
    refute result["isError"], inspect(result)
    Jason.decode!(Jason.encode!(result["structuredContent"]))
  end

  defp error(name, args, username) do
    {:ok, result} = Tools.call(name, args, username, "http://127.0.0.1:12995")
    assert result["isError"], inspect(result)
    hd(result["content"])["text"]
  end
end
