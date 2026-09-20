defmodule MDTClientWeb.HttpClientLiveTest do
  use MDTClientWeb.ConnCase

  import Phoenix.LiveViewTest

  alias MDTClient.HttpClient

  setup %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/tools/http")
    %{view: view, history: HttpClient.history()}
  end

  test "boots with open request tabs and the history panel", %{view: view, history: history} do
    assert has_element?(view, "#request-form")
    assert has_element?(view, "#request-url")
    assert count(view, "[phx-click=select_tab]") == 2
    assert count(view, "[phx-click=open_history]") == length(history)
  end

  test "the history is grouped by day, newest first", %{view: view, history: history} do
    labels = attributes(view, "[phx-click=toggle_group]", "phx-value-group")

    assert length(labels) == history |> HttpClient.group_history() |> length()
    assert labels == Enum.sort(labels, :desc)
    assert render(view) =~ "Today"
    assert render(view) =~ "Yesterday"
  end

  test "a history group can be collapsed and expanded", %{view: view, history: history} do
    [group | _] = attributes(view, "[phx-click=toggle_group]", "phx-value-group")
    in_group = Enum.count(history, &(Date.to_iso8601(NaiveDateTime.to_date(&1.at)) == group))

    view |> element("#group-#{group}") |> render_click()
    assert count(view, "[phx-click=open_history]") == length(history) - in_group

    view |> element("#group-#{group}") |> render_click()
    assert count(view, "[phx-click=open_history]") == length(history)
  end

  test "searching filters the history", %{view: view, history: history} do
    matches = history |> HttpClient.search_history("login") |> length()

    view
    |> element("form[phx-change=search]")
    |> render_change(%{"term" => "login"})

    assert count(view, "[phx-click=open_history]") == matches

    view |> element("[phx-click=clear_search]") |> render_click()

    assert count(view, "[phx-click=open_history]") == length(history)
  end

  test "searching with no match shows an empty state", %{view: view} do
    html =
      view
      |> element("form[phx-change=search]")
      |> render_change(%{"term" => "nothing-matches-this"})

    assert count(view, "[phx-click=open_history]") == 0
    assert html =~ "No request matches"
  end

  test "opening a history entry adds a tab", %{view: view} do
    id = first_attribute(view, "[phx-click=open_history]", "phx-value-id")

    view |> element("#history-#{id}") |> render_click()

    assert count(view, "[phx-click=select_tab]") == 3
  end

  test "new and close tab", %{view: view} do
    view |> element("[phx-click=new_tab]") |> render_click()
    assert count(view, "[phx-click=select_tab]") == 3

    id = first_attribute(view, "[phx-click=close_tab]", "phx-value-id")
    view |> element("[phx-click=close_tab][phx-value-id=#{id}]") |> render_click()

    assert count(view, "[phx-click=select_tab]") == 2
  end

  test "closing every tab shows the empty state", %{view: view} do
    for _ <- 1..2 do
      id = first_attribute(view, "[phx-click=close_tab]", "phx-value-id")
      view |> element("[phx-click=close_tab][phx-value-id=#{id}]") |> render_click()
    end

    assert render(view) =~ "No request open"
    refute has_element?(view, "#request-form")
  end

  test "editing the request updates the tab and the url", %{view: view} do
    view
    |> element("#request-form")
    |> render_change(%{
      "request" => %{"method" => "DELETE", "url" => "https://api.mdt.dev/v1/users/7"}
    })

    assert first_attribute(view, "#request-url", "value") == "https://api.mdt.dev/v1/users/7"
    assert render(view) =~ "DELETE"
  end

  test "sending a request renders a response and records history", %{
    view: view,
    history: history
  } do
    view |> element("[phx-click=set_editor_tab][phx-value-tab=body]") |> render_click()

    view
    |> element("#request-form")
    |> render_submit(%{"request" => %{"url" => "https://api.mdt.dev/v1/users/42"}})

    assert has_element?(view, "[id^=response-body-]")
    assert render(view) =~ "200 OK"
    assert count(view, "[phx-click=open_history]") == length(history) + 1
  end

  test "sending without a url is rejected", %{view: view} do
    view |> element("[phx-click=new_tab]") |> render_click()

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

  test "clearing the history empties the panel", %{view: view} do
    view |> element("[phx-click=clear_history]") |> render_click()

    assert count(view, "[phx-click=open_history]") == 0
    assert render(view) =~ "Nothing here yet"
  end

  test "the editor tabs swap the panel below the url", %{view: view} do
    view |> element("[phx-click=set_editor_tab][phx-value-tab=auth]") |> render_click()
    assert has_element?(view, "#request_auth_type")

    view |> element("[phx-click=set_editor_tab][phx-value-tab=body]") |> render_click()
    refute has_element?(view, "#request-body")

    view |> element("#request-form") |> render_change(%{"request" => %{"body_type" => "json"}})
    assert has_element?(view, "#request-body")
    assert has_element?(view, "[phx-click=format_body]")

    view |> element("[phx-click=set_editor_tab][phx-value-tab=headers]") |> render_click()
    assert count(view, "[phx-click=remove_row]") == 2
  end

  test "the response headers can be inspected", %{view: view} do
    view |> element("[phx-click=set_response_tab][phx-value-tab=headers]") |> render_click()

    assert render(view) =~ "x-ratelimit-remaining"
    refute has_element?(view, "[id^=response-body-]")
  end

  test "invalid JSON bodies are not formatted", %{view: view} do
    view |> element("[phx-click=set_editor_tab][phx-value-tab=body]") |> render_click()

    view
    |> element("#request-form")
    |> render_change(%{"request" => %{"body_type" => "json", "body" => "{not json"}})

    assert render_click(element(view, "[phx-click=format_body]")) =~ "not valid JSON"
  end

  test "the request can be exported as curl", %{view: view} do
    refute has_element?(view, "#curl-dialog")

    html =
      view
      |> element("[phx-click=open_dialog][phx-value-dialog=export_curl]")
      |> render_click()

    assert has_element?(view, "#curl-export")
    assert has_element?(view, "#copy-curl[data-copy]")
    assert html =~ "curl --request GET"
    assert html =~ "https://api.mdt.dev/v1/users"

    view |> element("[phx-click=close_dialog]", "Close") |> render_click()
    refute has_element?(view, "#curl-dialog")
  end

  test "a curl command is imported into a new tab", %{view: view} do
    tabs = count(view, "[phx-click=select_tab]")

    view |> element("[phx-click=open_dialog][phx-value-dialog=import_curl]") |> render_click()

    view
    |> element("#curl-dialog form")
    |> render_submit(%{"command" => "curl -X DELETE https://api.mdt.dev/v1/orders/ord_9f31"})

    refute has_element?(view, "#curl-dialog")
    assert count(view, "[phx-click=select_tab]") == tabs + 1

    assert first_attribute(view, "#request-url", "value") ==
             "https://api.mdt.dev/v1/orders/ord_9f31"

    assert render(view) =~ "Request imported from curl"
  end

  test "an unreadable curl command keeps the dialog open", %{view: view} do
    view |> element("[phx-click=open_dialog][phx-value-dialog=import_curl]") |> render_click()

    view |> element("#curl-dialog form") |> render_submit(%{"command" => "wget https://mdt.dev"})

    assert has_element?(view, "#curl-import-error")
    assert has_element?(view, "#curl-dialog")
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
