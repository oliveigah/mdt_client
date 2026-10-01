defmodule MDTClientWeb.NotesLiveTest do
  use MDTClientWeb.ConnCase

  import Phoenix.LiveViewTest

  alias MDTClient.Notes.Library
  alias MDTClient.Notes.Note
  alias MDTClient.VaultHelpers

  setup %{conn: conn} do
    VaultHelpers.reset_data_dir!()
    on_exit(&VaultHelpers.reset_data_dir!/0)
    sign_in(conn)
  end

  describe "with no notes" do
    setup %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/tools/notes")
      %{view: view}
    end

    test "opens a draft that is not listed until something is written", %{
      view: view,
      username: username
    } do
      assert has_element?(view, "#note-status", "Draft")
      assert has_element?(view, "#note-done[disabled]")
      refute has_element?(view, "[phx-click=open_note]")

      id = current_id(view)

      # A blank edit from a draft keeps nothing.
      edit(view, id, %{"title" => "", "body" => "  "})
      assert Library.list(username) == []

      edit(view, id, %{"title" => "", "body" => "- [ ] Renew the certificate"})

      assert has_element?(view, "#note-#{id}", "Renew the certificate")
      assert has_element?(view, "#note-status", "Saved")
      assert has_element?(view, "#note-preview input[type=checkbox]")
      refute has_element?(view, "#note-done[disabled]")
      assert {:ok, %{body: "- [ ] Renew the certificate"}} = Library.get(username, id)
    end

    test "naming a draft keeps it", %{view: view, username: username} do
      id = current_id(view)

      edit(view, id, %{"title" => "Ideas", "body" => ""})

      assert has_element?(view, "#note-#{id}", "Ideas")
      assert {:ok, %{title: "Ideas", body: ""}} = Library.get(username, id)
    end
  end

  describe "with notes" do
    setup %{conn: conn, username: username} do
      {:ok, older} =
        Library.save(username, Note.new_id(), %{
          title: "Release",
          body: "Bump the version\nTag the build"
        })

      {:ok, newer} =
        Library.save(username, Note.new_id(), %{title: "Groceries", body: "# Milk\nEggs"})

      {:ok, view, _html} = live(conn, ~p"/tools/notes")
      %{view: view, older: older, newer: newer}
    end

    test "opens the note changed last, rendered beside its Markdown", %{view: view, newer: newer} do
      assert current_id(view) == newer.id
      assert has_element?(view, "#note-row-#{newer.id}[class*=bg-active]")
      assert has_element?(view, "#note-title-#{newer.id}[value=Groceries]")
      assert has_element?(view, "#note-body-#{newer.id}", "# Milk")
      assert has_element?(view, "#note-preview h1", "Milk")
      # The list shows each body's first line.
      assert has_element?(view, "#note-#{newer.id}", "Milk")
    end

    test "opening a note from the list", %{view: view, older: older} do
      view |> element("#note-#{older.id}") |> render_click()

      assert current_id(view) == older.id
      assert has_element?(view, "#note-title-#{older.id}[value=Release]")
      assert has_element?(view, "#note-preview p", "Bump the version")
    end

    test "editing saves the title and body and renders them", %{
      view: view,
      username: username,
      newer: newer
    } do
      edit(view, newer.id, %{"title" => "Shopping", "body" => "**Bread**"})

      assert {:ok, %{title: "Shopping", body: "**Bread**"}} = Library.get(username, newer.id)
      assert has_element?(view, "#note-#{newer.id}", "Shopping")
      assert has_element?(view, "#note-preview strong", "Bread")
    end

    test "an edit that lands after switching still reaches the note it was for", %{
      view: view,
      username: username,
      older: older,
      newer: newer
    } do
      view |> element("#note-#{older.id}") |> render_click()

      render_change(view, "edit", %{"note_id" => newer.id, "body" => "Late"})

      assert {:ok, %{body: "Late"}} = Library.get(username, newer.id)
      assert current_id(view) == older.id
    end

    test "edits for a note that is gone are dropped", %{view: view, username: username} do
      render_change(view, "edit", %{"note_id" => Note.new_id(), "body" => "Ghost"})

      assert length(Library.list(username)) == 2
    end

    test "marking done moves a note to the done group, and back", %{
      view: view,
      username: username,
      older: older
    } do
      assert has_element?(view, "#note-group-open #note-row-#{older.id}")
      refute has_element?(view, "#note-group-done")

      view |> element("#note-done-#{older.id}") |> render_click()

      assert has_element?(view, "#note-group-done #note-row-#{older.id}")
      assert has_element?(view, "#note-done-#{older.id}[aria-checked=true]")
      assert {:ok, %{done_at: %DateTime{}}} = Library.get(username, older.id)

      view |> element("#note-done-#{older.id}") |> render_click()

      assert has_element?(view, "#note-group-open #note-row-#{older.id}")
      refute has_element?(view, "#note-group-done")
    end

    test "the open note can be marked done from its bar", %{view: view, newer: newer} do
      view |> element("#note-done") |> render_click()

      assert has_element?(view, "#note-done[aria-checked=true]")
      assert has_element?(view, "#note-status", "Done")
      assert has_element?(view, "#note-group-done #note-row-#{newer.id}")
    end

    test "searching finds words written anywhere in a note and marks them", %{
      view: view,
      older: older,
      newer: newer
    } do
      view |> element("#note-search") |> render_change(%{"term" => "VERSION release"})

      assert has_element?(view, "#note-#{older.id}")
      refute has_element?(view, "#note-#{newer.id}")
      assert has_element?(view, "#note-#{older.id} mark", "version")

      # Done notes are found too.
      view |> element("#note-done-#{older.id}") |> render_click()
      assert has_element?(view, "#note-group-done #note-#{older.id}")

      view |> element("#note-search") |> render_change(%{"term" => "shipping"})
      assert has_element?(view, "#note-list", "No note mentions")

      view |> element("#note-search [phx-click=clear_search]") |> render_click()
      assert has_element?(view, "#note-#{newer.id}")
    end

    test "deleting the open note moves on to the next one", %{
      view: view,
      username: username,
      older: older,
      newer: newer
    } do
      view |> element("#note-row-#{newer.id} [phx-click=delete_note]") |> render_click()

      refute has_element?(view, "#note-#{newer.id}")
      assert current_id(view) == older.id
      assert Library.get(username, newer.id) == :error

      view |> element("#note-row-#{older.id} [phx-click=delete_note]") |> render_click()
      assert has_element?(view, "#note-status", "Draft")
      assert Library.list(username) == []
    end

    test "the context menu acts on the row it was opened from", %{
      view: view,
      username: username,
      older: older
    } do
      render_hook(view, "open_menu", %{"kind" => "note", "id" => older.id, "x" => 10, "y" => 20})
      assert has_element?(view, "#note-menu-done", "Mark done")

      view |> element("#note-menu-done") |> render_click()
      refute has_element?(view, "#note-menu")
      assert {:ok, %{done_at: %DateTime{}}} = Library.get(username, older.id)

      render_hook(view, "open_menu", %{"kind" => "note", "id" => older.id})
      assert has_element?(view, "#note-menu-done", "Reopen")

      view |> element("#note-menu-open") |> render_click()
      assert current_id(view) == older.id
    end

    test "a new note starts as a draft", %{view: view} do
      view |> element("#new-note") |> render_click()

      assert has_element?(view, "#note-status", "Draft")
      assert has_element?(view, "[id^=note-title-][phx-mounted]")
    end

    test "switches between writing, both side by side, and reading", %{view: view} do
      assert has_element?(view, "#note-mode-split[aria-checked=true]")

      view |> element("#note-mode-write") |> render_click()
      assert has_element?(view, "#note-preview-pane.hidden")
      refute has_element?(view, "#note-write-pane.hidden")

      view |> element("#note-mode-preview") |> render_click()
      assert has_element?(view, "#note-write-pane.hidden")
      refute has_element?(view, "#note-preview-pane.hidden")
    end

    test "the list can be hidden and shown again", %{view: view} do
      view |> element("#note-list-panel [phx-click=toggle_sidebar]") |> render_click()
      refute has_element?(view, "#note-list-panel")

      view |> element("#show-note-list") |> render_click()
      assert has_element?(view, "#note-list-panel")
    end

    test "shows what is written elsewhere as it happens", %{
      view: view,
      username: username,
      older: older,
      newer: newer
    } do
      from_elsewhere = fn fun -> Task.async(fun) |> Task.await() end

      from_elsewhere.(fn ->
        Library.save(username, newer.id, %{title: "Groceries", body: "# Bread"})
      end)

      assert has_element?(view, "#note-preview h1", "Bread")

      from_elsewhere.(fn -> Library.set_done(username, older.id, true) end)
      assert has_element?(view, "#note-group-done #note-row-#{older.id}")

      id = Note.new_id()
      from_elsewhere.(fn -> Library.save(username, id, %{title: "From an agent"}) end)
      assert has_element?(view, "#note-#{id}", "From an agent")

      # The open note deleted elsewhere gives way to the next.
      from_elsewhere.(fn -> Library.delete(username, newer.id) end)
      refute has_element?(view, "#note-#{newer.id}")
      assert current_id(view) == id
    end
  end

  test "the tool picker and title bar offer notes", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/tools")

    assert has_element?(view, "#tool-notes")
    assert has_element?(view, "#tool-switch-notes", "Notes")
  end

  defp current_id(view) do
    [form] =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("form[id^=note-form-]")
      |> Enum.to_list()

    [id] = LazyHTML.attribute(form, "id")
    String.replace_prefix(id, "note-form-", "")
  end

  defp edit(view, id, params) do
    view |> form("#note-form-#{id}") |> render_change(params)
  end
end
