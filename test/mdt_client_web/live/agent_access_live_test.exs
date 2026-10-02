defmodule MDTClientWeb.AgentAccessLiveTest do
  use MDTClientWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  alias MDTClient.MCP.{Access, Tools}
  alias MDTClient.Vault.Store

  setup %{conn: conn} do
    sign_in(conn)
  end

  test "enables, rotates and revokes agent access from the connection screen", %{
    conn: conn,
    username: username
  } do
    {:ok, view, _html} = live(conn, ~p"/agents")
    assert has_element?(view, "#mcp-url")
    assert has_element?(view, "#issue-mcp-token")
    refute has_element?(view, "#mcp-credentials")
    refute Access.enabled?(username)

    view |> element("#issue-mcp-token") |> render_click()
    token = token(view)
    assert {:ok, ^username} = Access.authorize(token)
    assert has_element?(view, "#mcp-config")
    assert has_element?(view, "#copy-mcp-config")
    assert has_element?(view, "#revoke-mcp-token")

    view |> element("#issue-mcp-token") |> render_click()
    rotated = token(view)
    assert Access.authorize(token) == :error
    assert {:ok, ^username} = Access.authorize(rotated)

    view |> element("#revoke-mcp-token") |> render_click()
    refute has_element?(view, "#mcp-credentials")
    refute has_element?(view, "#revoke-mcp-token")
    assert Access.authorize(rotated) == :error
  end

  test "revisiting after unlocking keeps the configured token active without revealing it", %{
    conn: conn,
    username: username
  } do
    {:ok, token} = Access.issue(username)
    :ok = Store.close(username)
    {:ok, _profile, key} = MDTClient.Accounts.sign_in(username, "correct horse")
    :ok = Store.open(username, key)
    {:ok, view, _html} = live(conn, ~p"/agents")
    assert has_element?(view, "#mcp-existing-token")
    assert has_element?(view, "#mcp-token-lifetime")
    refute has_element?(view, "#mcp-token")
    assert {:ok, ^username} = Access.authorize(token)
  end

  test "offers the connection screen from the tools page and requires an unlocked identity", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/tools")
    assert has_element?(view, "#agent-access-link[href='/agents']")
    assert has_element?(view, "#connect-agent[href='/agents']")
    assert {:error, {:redirect, %{to: "/"}}} = live(build_conn(), ~p"/agents")
  end

  test "malformed HTTP item links keep the editor usable", %{conn: conn} do
    for path <- ["/tools/http?id=123abc", "/tools/http?id=-1", "/tools/http?id[]=1"] do
      {:ok, view, _html} = live(conn, path)
      assert has_element?(view, "#request-form")
    end
  end

  test "token changes refresh other open connection screens", %{conn: conn, username: username} do
    {:ok, first, _html} = live(conn, ~p"/agents")
    {:ok, second, _html} = live(conn, ~p"/agents")
    first |> element("#issue-mcp-token") |> render_click()
    first_token = token(first)
    assert has_element?(second, "#mcp-existing-token")
    second |> element("#issue-mcp-token") |> render_click()
    second_token = token(second)
    assert Access.authorize(first_token) == :error
    assert {:ok, ^username} = Access.authorize(second_token)
    refute has_element?(first, "#mcp-token")
    first |> element("#revoke-mcp-token") |> render_click()
    refute has_element?(second, "#mcp-credentials")
    refute Access.enabled?(username)
  end

  test "agent saves appear in open pages and direct links open the saved item", %{
    conn: conn,
    username: username
  } do
    {:ok, notes_view, _html} = live(conn, ~p"/tools/notes")
    note = create("create_note", %{"title" => "Agent note", "body" => "# Hello"}, username)
    assert has_element?(notes_view, "#note-#{note.id}")
    {:ok, note_link, _html} = live(conn, note.path)
    assert has_element?(note_link, "#note-body-#{note.id}")

    {:ok, diagram_view, _html} = live(conn, ~p"/tools/diagrams")
    diagram = create("create_diagram", %{"title" => "Agent diagram", "elements" => []}, username)
    assert has_element?(diagram_view, "#diagram-#{diagram.id}")
    create("create_diagram", %{"title" => "Newer diagram", "elements" => []}, username)
    {:ok, diagram_link, _html} = live(conn, diagram.path)
    assert has_element?(diagram_link, "#diagram-title[value='Agent diagram']")

    {:ok, http_view, _html} = live(conn, ~p"/tools/http")

    request =
      create(
        "create_http_request",
        %{"url" => "https://example.test/sample", "description" => "Agent sample"},
        username
      )

    assert has_element?(http_view, "#history-#{request.id}", "Saved sample")
    {:ok, request_link, _html} = live(conn, request.path)
    render_async(request_link)
    assert has_element?(request_link, "#request-url[value='https://example.test/sample']")
  end

  test "agent updates refresh the selected note and diagram in open pages", %{
    conn: conn,
    username: username
  } do
    note = create("create_note", %{"title" => "Agent note", "body" => "Old body"}, username)
    {:ok, notes_view, _html} = live(conn, note.path)

    create(
      "update_note",
      %{"id" => note.id, "title" => "Updated note", "body" => "# Updated body"},
      username
    )

    assert has_element?(notes_view, "#note-#{note.id}", "Updated note")
    assert has_element?(notes_view, "#note-title-#{note.id}[value='Updated note']")
    assert has_element?(notes_view, "#note-body-#{note.id}", "# Updated body")
    assert has_element?(notes_view, "#note-preview h1", "Updated body")

    diagram = create("create_diagram", %{"title" => "Agent diagram", "elements" => []}, username)
    {:ok, diagrams_view, _html} = live(conn, diagram.path)
    id = diagram.id

    elements = [
      %{
        "id" => "updated",
        "type" => "rectangle",
        "x" => 20,
        "y" => 40,
        "width" => 180,
        "height" => 80,
        "text" => "Updated shape"
      }
    ]

    create(
      "update_diagram",
      %{"id" => id, "title" => "Updated diagram", "elements" => elements},
      username
    )

    assert has_element?(diagrams_view, "#diagram-#{id}", "Updated diagram")
    assert has_element?(diagrams_view, "#diagram-title[value='Updated diagram']")

    assert_push_event(diagrams_view, "diagram:load", %{
      id: ^id,
      elements: [%{"id" => "updated", "text" => "Updated shape"}]
    })
  end

  defp token(view),
    do:
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#mcp-token")
      |> LazyHTML.text()
      |> String.trim()

  defp create(name, args, username) do
    {:ok, result} = Tools.call(name, args, username, "http://127.0.0.1:12995")
    refute result["isError"]
    result["structuredContent"]
  end
end
