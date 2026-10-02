defmodule MDTClientWeb.DiagramsLiveTest do
  use MDTClientWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import MDTClientWeb.PanelComponents, only: [page_size: 0]

  alias MDTClient.Diagrams.Diagram
  alias MDTClient.Diagrams.Library

  setup %{conn: conn} do
    sign_in(conn)
  end

  describe "with no diagrams" do
    setup %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/tools/diagrams")
      %{view: view}
    end

    test "opens a draft canvas that is not listed until something is drawn", %{
      view: view,
      username: username
    } do
      assert has_element?(view, "#diagram-canvas[phx-hook=DiagramEditor]")
      assert has_element?(view, "#diagram-toolbar #diagram-tool-rectangle")
      # The hook draws ports in a layer of their own.
      assert has_element?(view, "#diagram-svg [data-role=ports]")
      assert has_element?(view, "#diagram-status", "Draft")
      refute has_element?(view, "[phx-click=open_diagram]")

      id = ready(view).id

      # An empty save from a draft keeps nothing.
      render_hook(view, "save", %{"id" => id, "elements" => []})
      assert Library.list(username) == []

      render_hook(view, "save", %{"id" => id, "elements" => [box("a", "Orders service")]})

      assert has_element?(view, "#diagram-#{id}")
      assert has_element?(view, "#diagram-status", "Saved")
      assert {:ok, %{elements: [%{"text" => "Orders service"}]}} = Library.get(username, id)
    end

    test "naming a draft keeps it", %{view: view, username: username} do
      id = ready(view).id

      view |> element("#diagram-title-form") |> render_change(%{"title" => "Checkout flow"})

      assert has_element?(view, "#diagram-#{id}", "Checkout flow")
      assert {:ok, %{title: "Checkout flow", elements: []}} = Library.get(username, id)
    end
  end

  describe "with diagrams" do
    setup %{conn: conn, username: username} do
      {:ok, older} =
        Library.save(username, Diagram.new_id(), %{
          title: "Checkout",
          elements: [box("a", "Payment gateway"), box("b", "Fraud check")]
        })

      {:ok, newer} =
        Library.save(username, Diagram.new_id(), %{
          title: "Platform",
          elements: [box("c", "Billing queue")]
        })

      {:ok, view, _html} = live(conn, ~p"/tools/diagrams")
      %{view: view, older: older, newer: newer}
    end

    test "opens the diagram changed last", %{view: view, newer: newer} do
      assert %{id: id, elements: [%{"text" => "Billing queue"}], terms: []} = ready(view)
      assert id == newer.id
      assert has_element?(view, "#diagram-row-#{newer.id}[class*=bg-active]")
      assert has_element?(view, "#diagram-title[value=Platform]")
    end

    test "opening a diagram from the list loads it into the canvas", %{view: view, older: older} do
      older_id = older.id
      view |> element("#diagram-#{older_id}") |> render_click()

      assert_push_event(view, "diagram:load", %{
        id: ^older_id,
        elements: [%{"text" => "Payment gateway"}, %{"text" => "Fraud check"}]
      })

      assert has_element?(view, "#diagram-title[value=Checkout]")
    end

    test "searching finds words written anywhere in a diagram and marks them", %{
      view: view,
      older: older,
      newer: newer
    } do
      view |> element("#diagram-search") |> render_change(%{"term" => "FRAUD payment"})

      assert has_element?(view, "#diagram-#{older.id}")
      refute has_element?(view, "#diagram-#{newer.id}")
      assert has_element?(view, "#diagram-#{older.id} mark", "Payment")
      assert_push_event(view, "diagram:highlight", %{terms: ["fraud", "payment"]})

      # Opening a match carries the words, so the canvas marks them too.
      older_id = older.id
      view |> element("#diagram-#{older_id}") |> render_click()
      assert_push_event(view, "diagram:load", %{id: ^older_id, terms: ["fraud", "payment"]})

      view |> element("#diagram-search") |> render_change(%{"term" => "shipping"})
      assert has_element?(view, "#diagram-list", "No diagram mentions")

      view |> element("[phx-click=clear_search]") |> render_click()
      assert has_element?(view, "#diagram-#{newer.id}")
      assert_push_event(view, "diagram:highlight", %{terms: []})
    end

    test "a save that lands after switching still reaches the diagram it was for", %{
      view: view,
      username: username,
      older: older,
      newer: newer
    } do
      view |> element("#diagram-#{older.id}") |> render_click()
      render_hook(view, "save", %{"id" => newer.id, "elements" => [box("c", "Billing topic")]})

      assert {:ok, %{elements: [%{"text" => "Billing topic"}]}} = Library.get(username, newer.id)
      assert has_element?(view, "#diagram-title[value=Checkout]")
    end

    test "saves for a diagram that is gone are dropped", %{view: view, username: username} do
      render_hook(view, "save", %{"id" => Diagram.new_id(), "elements" => [box("z", "Ghost")]})

      assert length(Library.list(username)) == 2
    end

    test "duplicating opens the copy", %{view: view, username: username, older: older} do
      view
      |> element("#diagram-row-#{older.id} [phx-click=duplicate_diagram]")
      |> render_click()

      assert [%{title: "Checkout copy", id: copy_id} | _] = Library.list(username)
      assert_push_event(view, "diagram:load", %{id: ^copy_id})
      assert has_element?(view, "#diagram-title[value='Checkout copy']")
    end

    test "deleting the open diagram moves on to the next one", %{
      view: view,
      username: username,
      older: older,
      newer: newer
    } do
      view |> element("#diagram-row-#{newer.id} [phx-click=delete_diagram]") |> render_click()

      older_id = older.id
      refute has_element?(view, "#diagram-#{newer.id}")
      assert_push_event(view, "diagram:load", %{id: ^older_id})
      assert Library.get(username, newer.id) == :error

      view |> element("#diagram-row-#{older.id} [phx-click=delete_diagram]") |> render_click()
      assert has_element?(view, "#diagram-status", "Draft")
      assert Library.list(username) == []
    end

    test "the context menu acts on the row it was opened from", %{view: view, older: older} do
      render_hook(view, "open_menu", %{
        "kind" => "diagram",
        "id" => older.id,
        "x" => 10,
        "y" => 20
      })

      assert has_element?(view, "#diagram-menu")

      older_id = older.id
      view |> element("#diagram-menu-open") |> render_click()
      refute has_element?(view, "#diagram-menu")
      assert_push_event(view, "diagram:load", %{id: ^older_id})
    end

    test "a new diagram starts as a draft", %{view: view} do
      view |> element("#new-diagram") |> render_click()

      assert_push_event(view, "diagram:load", %{elements: []})
      assert has_element?(view, "#diagram-status", "Draft")
    end

    test "the canvas can pick up a diagram after a reconnect", %{view: view, older: older} do
      render_hook(view, "editor_resume", %{"id" => older.id})

      assert has_element?(view, "#diagram-title[value=Checkout]")
    end

    test "the list can be hidden and shown again", %{view: view} do
      view |> element("#diagram-list-panel [phx-click=toggle_sidebar]") |> render_click()
      refute has_element?(view, "#diagram-list-panel")

      view |> element("#show-diagram-list") |> render_click()
      assert has_element?(view, "#diagram-list-panel")
    end
  end

  test "the tool picker and title bar offer diagrams", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/tools")

    assert has_element?(view, "#tool-diagrams")
    assert has_element?(view, "#tool-switch-diagrams", "Diagrams")
  end

  test "draws the first page of a long list and loads the rest on demand", %{
    conn: conn,
    username: username
  } do
    for n <- 1..(page_size() + 2) do
      {:ok, _diagram} =
        Library.save(username, Diagram.new_id(), %{
          title: "Flow #{n}",
          elements: [box("a", "Payment gateway")]
        })
    end

    {:ok, view, _html} = live(conn, ~p"/tools/diagrams")

    assert count(view, "#diagram-list [role=option]") == page_size()
    assert has_element?(view, "#diagram-more", "2 more")

    view |> element("#diagram-more") |> render_click()
    assert count(view, "#diagram-list [role=option]") == page_size() + 2
    refute has_element?(view, "#diagram-more")

    # A search starts again from the first page, marking what is drawn.
    view |> element("#diagram-search") |> render_change(%{"term" => "gateway"})
    assert count(view, "#diagram-list mark") == page_size()
    assert has_element?(view, "#diagram-more", "2 more")
  end

  defp count(view, selector) do
    view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query(selector) |> Enum.count()
  end

  defp ready(view) do
    render_hook(view, "editor_ready", %{})
    assert_reply(view, reply)
    reply
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
end
