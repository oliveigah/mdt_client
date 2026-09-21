defmodule MDTClientWeb.HttpClientLiveTest do
  use MDTClientWeb.ConnCase

  import Phoenix.LiveViewTest

  alias MDTClient.HttpClient.HistoryMetadata
  alias MDTClient.HttpClient.Resources
  alias MDTClient.VaultHelpers

  setup %{conn: conn} do
    VaultHelpers.reset_data_dir!()
    on_exit(&VaultHelpers.reset_data_dir!/0)
    %{conn: conn, username: username} = sign_in(conn)

    health_request =
      Req.new(
        method: :get,
        url: "https://api.example.test/health",
        headers: [{"accept", "application/json"}]
      )

    health_response = %Req.Response{
      status: 200,
      headers: %{"content-type" => ["application/json"], "x-ratelimit-remaining" => ["4998"]},
      body: %{"status" => "ok"}
    }

    health_id =
      Resources.record(
        username,
        HistoryMetadata.new(%{description: "Health check", tags: ["system", "health"]}),
        health_request,
        health_response
      )

    Resources.record(
      username,
      HistoryMetadata.new(%{description: "Create order", tags: ["orders"]}),
      Req.new(method: :post, url: "https://api.example.test/orders", body: ~s({"sku":"MDT-PRO"})),
      %Req.Response{status: 201, headers: %{}, body: %{"id" => "ord_1"}}
    )

    {:ok, view, _html} = live(conn, ~p"/tools/http")
    %{view: view, health_id: health_id, username: username, conn: conn}
  end

  test "boots with a blank request and persisted history", %{view: view} do
    assert has_element?(view, "#request-form")
    assert has_element?(view, "#request-url")
    assert count(view, "[phx-click=select_tab]") == 1
    assert count(view, "[phx-click=open_history]") == 2
  end

  test "history rows carry the host on its own line", %{view: view, health_id: health_id} do
    row = view |> element("#history-#{health_id}") |> render()

    assert row =~ "api.example.test"
    assert row =~ "/health"
  end

  test "a non default port is shown with the host", %{conn: conn, username: username} do
    Resources.record(
      username,
      HistoryMetadata.new(%{description: "Local"}),
      Req.new(method: :get, url: "http://localhost:4000/health"),
      %Req.Response{status: 200, headers: %{}, body: "ok"}
    )

    {:ok, view, _html} = live(conn, ~p"/tools/http")

    assert render(view) =~ "localhost:4000"
  end

  test "searching uses persisted history", %{view: view} do
    view
    |> element("form[phx-change=search]")
    |> render_change(%{"term" => "SYSTEM"})

    assert count(view, "[phx-click=open_history]") == 1
    assert render(view) =~ "Health check"

    view |> element("[phx-click=clear_search]") |> render_click()
    assert count(view, "[phx-click=open_history]") == 2
  end

  test "searching with no match shows an empty state", %{view: view} do
    html =
      view
      |> element("form[phx-change=search]")
      |> render_change(%{"term" => "nothing-matches-this"})

    assert count(view, "[phx-click=open_history]") == 0
    assert html =~ "No request matches"
  end

  test "opening persisted history restores its request and response", %{
    view: view,
    health_id: health_id
  } do
    view |> element("#history-#{health_id}") |> render_click()

    assert count(view, "[phx-click=select_tab]") == 2
    assert first_attribute(view, "#request-url", "value") == "https://api.example.test/health"
    assert render(view) =~ "200 OK"

    view |> element("[phx-click=set_response_tab][phx-value-tab=headers]") |> render_click()
    assert render(view) =~ "x-ratelimit-remaining"
  end

  test "new and close tab", %{view: view} do
    view |> element("[phx-click=new_tab]") |> render_click()
    assert count(view, "[phx-click=select_tab]") == 2

    id = first_attribute(view, "[phx-click=close_tab]", "phx-value-id")
    view |> element("[phx-click=close_tab][phx-value-id=#{id}]") |> render_click()

    assert count(view, "[phx-click=select_tab]") == 1
  end

  test "closing every tab shows the empty state", %{view: view} do
    id = first_attribute(view, "[phx-click=close_tab]", "phx-value-id")
    view |> element("[phx-click=close_tab][phx-value-id=#{id}]") |> render_click()

    assert render(view) =~ "No request open"
    refute has_element?(view, "#request-form")
  end

  test "editing the request updates the tab and the URL", %{view: view} do
    view
    |> element("#request-form")
    |> render_change(%{
      "request" => %{"method" => "DELETE", "url" => "https://api.example.test/users/7"}
    })

    assert first_attribute(view, "#request-url", "value") == "https://api.example.test/users/7"
    assert render(view) =~ "DELETE"
  end

  test "sending without a URL is rejected", %{view: view} do
    html = render_submit(element(view, "#request-form"), %{"request" => %{"url" => "   "}})

    assert html =~ "Enter a URL before sending"
  end

  test "params rows can be added and removed", %{view: view} do
    before = count(view, "[phx-click=remove_row]")

    view |> element("[phx-click=add_row][phx-value-kind=param]") |> render_click()
    assert count(view, "[phx-click=remove_row]") == before + 1

    id = first_attribute(view, "[phx-click=remove_row]", "phx-value-id")
    view |> element("[phx-click=remove_row][phx-value-id=#{id}]") |> render_click()
    assert count(view, "[phx-click=remove_row]") == before
  end

  test "the history panel can be hidden and shown again", %{view: view} do
    view |> element("[phx-click=toggle_sidebar]") |> render_click()
    refute has_element?(view, "form[phx-change=search]")
    refute has_element?(view, "#history-resizer")

    view |> element("[phx-click=toggle_sidebar]") |> render_click()
    assert has_element?(view, "form[phx-change=search]")
    assert has_element?(view, "#history-resizer")
  end

  test "the panels carry resize handles", %{view: view} do
    assert has_element?(view, "#history-resizer[data-panel=history-panel]")
    assert has_element?(view, "#request-resizer[data-panel=request-editor]")
    assert has_element?(view, "#history-panel")
    assert has_element?(view, "#request-editor")
  end

  test "clearing history removes persisted entries", %{view: view, username: username} do
    view |> element("[phx-click=clear_history]") |> render_click()

    assert count(view, "[phx-click=open_history]") == 0
    assert render(view) =~ "Nothing here yet"
    assert Resources.all(username) == []
  end

  test "the editor tabs swap the panel below the URL", %{view: view} do
    view |> element("[phx-click=set_editor_tab][phx-value-tab=auth]") |> render_click()
    assert has_element?(view, "#request_auth_type")

    view |> element("[phx-click=set_editor_tab][phx-value-tab=body]") |> render_click()
    refute has_element?(view, "#request-body")

    view |> element("#request-form") |> render_change(%{"request" => %{"body_type" => "json"}})
    assert has_element?(view, "#request-body")
    assert has_element?(view, "[phx-click=format_body]")
  end

  test "invalid JSON bodies are not formatted", %{view: view} do
    view |> element("[phx-click=set_editor_tab][phx-value-tab=body]") |> render_click()

    view
    |> element("#request-form")
    |> render_change(%{"request" => %{"body_type" => "json", "body" => "{not json"}})

    assert render_click(element(view, "[phx-click=format_body]")) =~ "not valid JSON"
  end

  test "the request can be exported as curl", %{view: view} do
    view
    |> element("#request-form")
    |> render_change(%{"request" => %{"url" => "https://api.example.test/users"}})

    html =
      view
      |> element("[phx-click=open_dialog][phx-value-dialog=export_curl]")
      |> render_click()

    assert has_element?(view, "#curl-export")
    assert html =~ "curl --request GET"
    assert html =~ "https://api.example.test/users"
  end

  test "a curl command is imported into a new tab", %{view: view} do
    tabs = count(view, "[phx-click=select_tab]")

    view |> element("[phx-click=open_dialog][phx-value-dialog=import_curl]") |> render_click()

    view
    |> element("#curl-dialog form")
    |> render_submit(%{"command" => "curl -X DELETE https://api.example.test/orders/ord_1"})

    refute has_element?(view, "#curl-dialog")
    assert count(view, "[phx-click=select_tab]") == tabs + 1

    assert first_attribute(view, "#request-url", "value") ==
             "https://api.example.test/orders/ord_1"
  end

  test "a history entry is tagged from its own row", %{
    view: view,
    health_id: health_id,
    username: username
  } do
    view |> element(entry_action(health_id, "add_tag")) |> render_click()
    assert has_element?(view, "#metadata-dialog")

    html = view |> element("#metadata-form") |> render_submit(%{"value" => "smoke"})

    refute has_element?(view, "#metadata-dialog")
    assert html =~ "Tagged 1 request"
    assert metadata(username, health_id).tags == ["system", "health", "smoke"]
  end

  test "an empty tag is rejected and keeps the dialog open", %{
    view: view,
    health_id: health_id,
    username: username
  } do
    view |> element(entry_action(health_id, "add_tag")) |> render_click()

    html = view |> element("#metadata-form") |> render_submit(%{"value" => "   "})

    assert html =~ "Enter a tag"
    assert has_element?(view, "#metadata-dialog")
    assert metadata(username, health_id).tags == ["system", "health"]
  end

  test "a history entry description is prefilled, saved and cleared", %{
    view: view,
    health_id: health_id,
    username: username
  } do
    view |> element(entry_action(health_id, "set_description")) |> render_click()
    assert first_attribute(view, "#metadata-value", "value") == "Health check"

    html = view |> element("#metadata-form") |> render_submit(%{"value" => "Liveness probe"})

    assert html =~ "Described 1 request"
    assert html =~ "Liveness probe"
    assert metadata(username, health_id).description == "Liveness probe"

    view |> element(entry_action(health_id, "set_description")) |> render_click()
    view |> element("#metadata-form") |> render_submit(%{"value" => ""})

    assert metadata(username, health_id).description == nil
  end

  test "tags apply to every selected history entry", %{view: view, username: username} do
    ids = attributes(view, "[phx-click=open_history]", "phx-value-id")

    for id <- ids, do: view |> element("#select-history-#{id}") |> render_click()
    assert has_element?(view, "#history-selection")

    view |> element("#history-selection [phx-value-dialog=add_tag]") |> render_click()
    html = view |> element("#metadata-form") |> render_submit(%{"value" => "regression"})

    assert html =~ "Tagged 2 requests"
    for id <- ids, do: assert("regression" in metadata(username, id).tags)
  end

  test "the selection bar selects everything and clears", %{view: view, health_id: health_id} do
    refute has_element?(view, "#history-selection")

    view |> element("#select-history-#{health_id}") |> render_click()
    view |> element("[phx-click=select_all]") |> render_click()
    assert count(view, "[phx-click=toggle_select][aria-checked=true]") == 2

    view |> element("[phx-click=clear_selection]") |> render_click()
    refute has_element?(view, "#history-selection")
  end

  test "opening a history entry inherits its description and tags", %{
    view: view,
    health_id: health_id
  } do
    view |> element("#history-#{health_id}") |> render_click()

    assert first_attribute(view, "#request-description-input", "value") == "Health check"
    assert has_element?(view, "[phx-click=remove_tag][phx-value-tag=system]")
    assert has_element?(view, "[phx-click=remove_tag][phx-value-tag=health]")
  end

  test "the request panel edits its description and tags", %{view: view} do
    view |> element("#request-description") |> render_change(%{"description" => "Nightly smoke"})
    assert render(view) =~ "Nightly smoke"

    view |> element("#request-tag") |> render_submit(%{"tag" => "smoke"})
    assert has_element?(view, "[phx-click=remove_tag][phx-value-tag=smoke]")

    view |> element("#request-tag") |> render_submit(%{"tag" => " smoke "})
    view |> element("#request-tag") |> render_submit(%{"tag" => "  "})
    assert count(view, "[phx-click=remove_tag]") == 1

    view |> element("[phx-click=remove_tag][phx-value-tag=smoke]") |> render_click()
    refute has_element?(view, "[phx-click=remove_tag]")
  end

  test "a selected history entry is deleted", %{
    view: view,
    health_id: health_id,
    username: username
  } do
    view |> element(entry_action(health_id, "delete_entries")) |> render_click()

    assert count(view, "[phx-click=open_history]") == 1
    assert Resources.get(username, health_id) == :error
  end

  test "deleting works on the whole selection", %{view: view, username: username} do
    ids = attributes(view, "[phx-click=open_history]", "phx-value-id")
    for id <- ids, do: view |> element("#select-history-#{id}") |> render_click()

    html = view |> element("#history-selection [phx-click=delete_entries]") |> render_click()

    assert html =~ "Deleted 2 requests"
    assert html =~ "Nothing here yet"
    refute has_element?(view, "#history-selection")
    assert Resources.all(username) == []
  end

  test "sending records the description and tags of the tab", %{view: view, username: username} do
    Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 200, "ok") end)
    Req.Test.set_req_test_to_shared()
    Req.default_options(plug: {Req.Test, __MODULE__})

    on_exit(fn ->
      Req.default_options([])
      Req.Test.set_req_test_to_private()
    end)

    view |> element("#request-description") |> render_change(%{"description" => "Nightly smoke"})

    # typed into the tag box but never submitted with Enter
    view |> element("#request-tag") |> render_change(%{"tag" => "smoke"})
    refute has_element?(view, "[phx-click=remove_tag][phx-value-tag=smoke]")

    view
    |> element("#request-form")
    |> render_change(%{"request" => %{"url" => "https://api.example.test/ping"}})

    view |> element("#request-form") |> render_submit(%{})
    render_async(view)

    assert [{_id, metadata, _request, _response} | _older] = Resources.all(username)
    assert metadata.description == "Nightly smoke"
    assert metadata.tags == ["smoke"]
  end

  defp entry_action(id, "delete_entries"),
    do: ~s([phx-click=delete_entries][phx-value-id="#{id}"])

  defp entry_action(id, dialog),
    do: ~s([phx-click=open_metadata][phx-value-dialog=#{dialog}][phx-value-id="#{id}"])

  defp metadata(username, id) do
    {:ok, {_id, metadata, _request, _response}} =
      Resources.get(username, String.to_integer(to_string(id)))

    metadata
  end

  defp count(view, selector) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> Enum.count()
  end

  defp first_attribute(view, selector, attribute) do
    view |> attributes(selector, attribute) |> List.first()
  end

  defp attributes(view, selector, attribute) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute(attribute)
  end
end
