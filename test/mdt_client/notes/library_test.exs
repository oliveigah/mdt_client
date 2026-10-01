defmodule MDTClient.Notes.LibraryTest do
  use ExUnit.Case, async: false

  import MDTClient.VaultHelpers

  alias MDTClient.Accounts
  alias MDTClient.Notes.Library
  alias MDTClient.Notes.Note
  alias MDTClient.Vault.Store

  setup do
    unlocked_identity()
  end

  test "a note exists from its first save", %{username: username} do
    id = Note.new_id()
    assert Library.get(username, id) == :error

    {:ok, note} = Library.save(username, id, %{body: "- [ ] Renew the certificate"})

    assert {:ok, ^note} = Library.get(username, id)
    assert note.title == Note.default_title()
    assert {:ok, ^note} = Library.latest(username)
  end

  test "saving refuses identifiers that could not have come from here", %{username: username} do
    assert Library.save(username, "../../etc", %{title: "x"}) == {:error, :invalid_id}
    assert Library.list(username) == []
  end

  test "lists the most recently changed first, searching titles and bodies", %{
    username: username
  } do
    {:ok, first} = Library.save(username, Note.new_id(), %{title: "Groceries"})

    {:ok, second} =
      Library.save(username, Note.new_id(), %{
        title: "Release",
        body: "# Steps\nBump the version\nTag the build"
      })

    assert [%{id: second_id, excerpt: "Steps"}, %{id: first_id, excerpt: nil}] =
             Library.list(username)

    assert {second_id, first_id} == {second.id, first.id}

    assert [%{id: ^second_id, snippet: {"Bump the ", "version", ""}}] =
             Library.list(username, "VERSION release")

    assert [%{id: ^first_id, snippet: nil}] = Library.list(username, "groceries")
    assert Library.list(username, "shipping") == []

    # Saving the older one again brings it to the top.
    {:ok, _first} = Library.save(username, first.id, %{body: "Milk"})
    assert [%{id: ^first_id}, %{id: ^second_id}] = Library.list(username)
  end

  test "saving what is already there leaves the note where it was", %{username: username} do
    {:ok, note} = Library.save(username, Note.new_id(), %{title: "One", body: "Body"})

    assert {:ok, ^note} = Library.save(username, note.id, %{title: "One", body: "Body"})
  end

  test "marks notes done and open again", %{username: username} do
    {:ok, note} = Library.save(username, Note.new_id(), %{title: "Task"})

    assert {:ok, %{done_at: %DateTime{} = done_at} = done} =
             Library.set_done(username, note.id, true)

    # Asking again changes nothing.
    assert {:ok, ^done} = Library.set_done(username, note.id, true)
    assert [%{done_at: ^done_at}] = Library.list(username)

    assert {:ok, %{done_at: nil}} = Library.set_done(username, note.id, false)
    assert Library.set_done(username, Note.new_id(), true) == :error
  end

  test "deletes", %{username: username} do
    {:ok, note} = Library.save(username, Note.new_id(), %{title: "Gone soon"})

    assert Library.delete(username, note.id) == :ok
    assert Library.delete(username, note.id) == :error
    assert Library.list(username) == []
    assert Library.latest(username) == :error
  end

  test "notes are encrypted on disk and survive a restart", %{username: username, key: key} do
    {:ok, note} =
      Library.save(username, Note.new_id(), %{title: "Secret plans", body: "launch codes"})

    {:ok, note} = Library.set_done(username, note.id, true)

    :ok = Store.close(username)

    blob = File.read!(Accounts.store_path(username, "notes.bin"))
    refute blob =~ "launch codes"
    refute blob =~ "Secret plans"

    :ok = Store.open(username, key)
    assert {:ok, ^note} = Library.get(username, note.id)
  end

  test "rewrites everything in one step", %{username: username} do
    {:ok, _old} = Library.save(username, Note.new_id(), %{title: "Old"})

    :ok = Library.rewrite(username, fn [_old] -> [Note.new(%{title: "New"})] end)

    assert [%{title: "New"}] = Library.list(username)
  end

  describe "subscribers" do
    setup %{username: username} do
      :ok = Library.subscribe(username)
      {:ok, note} = Library.save(username, Note.new_id(), %{title: "Mine"})
      # The process that made a change already has the answer to its call.
      refute_received {:notes_changed, _id}
      %{note: note}
    end

    test "hear about changes made by anyone else", %{username: username, note: note} do
      id = note.id

      writer = fn fun -> Task.async(fun) |> Task.await() end

      writer.(fn -> Library.save(username, id, %{body: "From elsewhere"}) end)
      assert_receive {:notes_changed, ^id}

      writer.(fn -> Library.set_done(username, id, true) end)
      assert_receive {:notes_changed, ^id}

      # Nothing changed, so nothing is said.
      writer.(fn -> Library.set_done(username, id, true) end)
      refute_receive {:notes_changed, _id}, 50

      new_id = Note.new_id()
      writer.(fn -> Library.save(username, new_id, %{title: "New"}) end)
      assert_receive {:notes_changed, ^new_id}

      writer.(fn -> Library.delete(username, id) end)
      assert_receive {:notes_changed, ^id}

      writer.(fn -> Library.rewrite(username, & &1) end)
      assert_receive {:notes_changed, :all}
    end
  end
end
