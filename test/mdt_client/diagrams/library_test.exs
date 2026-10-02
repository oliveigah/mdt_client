defmodule MDTClient.Diagrams.LibraryTest do
  use ExUnit.Case, async: true

  import MDTClient.VaultHelpers

  alias MDTClient.Accounts
  alias MDTClient.Diagrams.Diagram
  alias MDTClient.Diagrams.Library
  alias MDTClient.Vault.Store

  setup do
    unlocked_identity()
  end

  test "a diagram exists from its first save", %{username: username} do
    id = Diagram.new_id()
    assert Library.get(username, id) == :error

    {:ok, diagram} = Library.save(username, id, %{elements: [box("a", "Orders")]})

    assert {:ok, ^diagram} = Library.get(username, id)
    assert diagram.title == Diagram.default_title()
    assert [%{"id" => "a", "text" => "Orders"}] = diagram.elements
    assert {:ok, ^diagram} = Library.latest(username)
  end

  test "saving refuses identifiers that could not have come from here", %{username: username} do
    assert Library.save(username, "../../etc", %{title: "x"}) == {:error, :invalid_id}
    assert Library.list(username) == []
  end

  test "lists the most recently changed first, searching every word drawn", %{
    username: username
  } do
    {:ok, first} = Library.save(username, Diagram.new_id(), %{title: "Checkout"})

    {:ok, second} =
      Library.save(username, Diagram.new_id(), %{
        title: "Platform",
        elements: [box("a", "Payment gateway"), box("b", "Billing queue")]
      })

    assert [%{id: second_id}, %{id: first_id}] = Library.list(username)
    assert {second_id, first_id} == {second.id, first.id}

    assert [%{id: ^second_id, count: 2}] = Library.list(username, "billing GATEWAY")
    assert [%{id: ^first_id}] = Library.list(username, "checkout")
    assert Library.list(username, "shipping") == []

    # The snippet comes from the first element holding any of the words, and
    # there is none where only the title holds them.
    assert Library.snippets(username, [second_id, first_id], "billing GATEWAY") ==
             %{second_id => {"Payment ", "gateway", ""}}

    assert Library.snippets(username, [first_id], "checkout") == %{}
    assert Library.snippets(username, [second_id], "") == %{}
    assert Library.snippets(username, [Diagram.new_id()], "gateway") == %{}

    # Saving the older one again brings it to the top.
    {:ok, _first} = Library.save(username, first.id, %{elements: [box("c", "Cart")]})
    assert [%{id: ^first_id}, %{id: ^second_id}] = Library.list(username)
  end

  test "saving what is already there leaves the diagram where it was", %{username: username} do
    {:ok, diagram} = Library.save(username, Diagram.new_id(), %{elements: [box("a", "One")]})

    assert {:ok, ^diagram} = Library.save(username, diagram.id, %{elements: diagram.elements})
  end

  test "duplicates and deletes", %{username: username} do
    {:ok, diagram} =
      Library.save(username, Diagram.new_id(), %{title: "Flow", elements: [box("a", "A")]})

    {:ok, copy} = Library.duplicate(username, diagram.id)
    assert copy.id != diagram.id
    assert copy.title == "Flow copy"
    assert copy.elements == diagram.elements

    assert Library.delete(username, diagram.id) == :ok
    assert Library.delete(username, diagram.id) == :error
    assert Library.duplicate(username, diagram.id) == :error
    assert [%{id: copy_id}] = Library.list(username)
    assert copy_id == copy.id
  end

  test "diagrams are encrypted on disk and survive a restart", %{username: username, key: key} do
    {:ok, diagram} =
      Library.save(username, Diagram.new_id(), %{
        title: "Secret plans",
        elements: [box("a", "launch codes")]
      })

    :ok = Store.close(username)

    blob = File.read!(Accounts.store_path(username, "diagrams.bin"))
    refute blob =~ "launch codes"
    refute blob =~ "Secret plans"

    :ok = Store.open(username, key)
    assert {:ok, ^diagram} = Library.get(username, diagram.id)
  end

  test "rewrites everything in one step", %{username: username} do
    {:ok, _old} = Library.save(username, Diagram.new_id(), %{title: "Old"})

    :ok = Library.rewrite(username, fn [_old] -> [Diagram.new(%{title: "New"})] end)

    assert [%{title: "New"}] = Library.list(username)
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
