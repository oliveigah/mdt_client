defmodule MDTClient.Diagrams.TransferTest do
  use ExUnit.Case, async: true

  import MDTClient.VaultHelpers

  alias MDTClient.Diagrams.Diagram
  alias MDTClient.Diagrams.Library
  alias MDTClient.Diagrams.Transfer

  setup do
    unlocked_identity()
  end

  test "merging adds diagrams that are new here", %{username: username} do
    mine = keep(username, diagram("Mine", ~U[2026-09-01 10:00:00.000001Z]))

    :ok = merge(username, [diagram("Theirs", ~U[2026-09-02 10:00:00.000001Z])])

    assert titles(username) == ["Theirs", "Mine"]
    assert {:ok, ^mine} = Library.get(username, mine.id)
  end

  test "a diagram both sides hold keeps the version saved last", %{username: username} do
    older = diagram("Flow", ~U[2026-09-01 10:00:00.000001Z])
    newer = %{older | title: "Flow v2", updated_at: ~U[2026-09-05 10:00:00.000001Z]}

    keep(username, newer)
    :ok = merge(username, [older])
    assert titles(username) == ["Flow v2"]
  end

  test "when the imported version wins, the version here is kept beside it", %{
    username: username
  } do
    mine = keep(username, diagram("Flow", ~U[2026-09-01 10:00:00.000001Z], "local edit"))

    theirs = %{
      mine
      | updated_at: ~U[2026-09-05 10:00:00.000001Z],
        elements: elements("remote edit")
    }

    :ok = merge(username, [theirs])

    assert {:ok, %{elements: [%{"text" => "remote edit"}]}} = Library.get(username, mine.id)
    assert titles(username) == ["Flow", "Flow (before import)"]
    assert [%{id: kept}] = Library.list(username, "local")
    assert %{^kept => {_, "local", _}} = Library.snippets(username, [kept], "local")

    # Merging the same file again finds the copy already kept.
    :ok = merge(username, [theirs])
    assert length(Library.list(username)) == 2
  end

  test "an identical version saved later elsewhere just replaces this one", %{
    username: username
  } do
    mine = keep(username, diagram("Flow", ~U[2026-09-01 10:00:00.000001Z]))

    :ok = merge(username, [%{mine | updated_at: ~U[2026-09-05 10:00:00.000001Z]}])

    assert titles(username) == ["Flow"]
  end

  test "merging this identity's own export changes nothing", %{username: username} do
    keep(username, diagram("One", ~U[2026-09-01 10:00:00.000001Z]))
    keep(username, diagram("Two", ~U[2026-09-02 10:00:00.000001Z]))
    before = Library.all(username)

    {:ok, own} = Transfer.export(username)
    {:ok, own} = Transfer.prepare(1, own)
    :ok = Transfer.merge(username, own)

    assert Library.all(username) == before
  end

  test "replacing drops what is here", %{username: username} do
    keep(username, diagram("Mine", ~U[2026-09-01 10:00:00.000001Z]))

    :ok = Transfer.replace(username, [diagram("Theirs", DateTime.utc_now())])

    assert titles(username) == ["Theirs"]
  end

  test "exports plain maps and rebuilds the search text on the way in", %{username: username} do
    keep(username, diagram("Flow", ~U[2026-09-01 10:00:00.000001Z], "Gateway"))

    {:ok, %{diagrams: [exported]}} = Transfer.export(username)
    refute is_struct(exported)
    refute Map.has_key?(exported, :search_text)

    {:ok, [prepared]} = Transfer.prepare(1, %{diagrams: [exported]})
    assert prepared.search_text =~ "gateway"
    assert Transfer.describe([prepared]) == "1 diagram"
  end

  test "a damaged section is refused whole" do
    good =
      Map.take(diagram("Ok", DateTime.utc_now()), [
        :id,
        :title,
        :elements,
        :created_at,
        :updated_at
      ])

    assert {:error, _reason} = Transfer.prepare(1, %{diagrams: [good, %{id: "x"}]})
    assert {:error, _reason} = Transfer.prepare(1, %{diagrams: [%{good | id: "../x"}]})
    assert {:error, _reason} = Transfer.prepare(1, :nonsense)
    assert Transfer.describe([]) == "No diagrams"
  end

  defp diagram(title, at, text \\ "Box") do
    Diagram.new(%{title: title, elements: elements(text), created_at: at, updated_at: at})
  end

  defp elements(text) do
    [%{"id" => "a", "type" => "rectangle", "width" => 100, "height" => 50, "text" => text}]
  end

  # Straight into the library, timestamps and all.
  defp keep(username, diagram) do
    :ok = Library.rewrite(username, &(&1 ++ [diagram]))
    diagram
  end

  defp merge(username, diagrams) do
    data = %{
      diagrams:
        Enum.map(diagrams, &Map.take(&1, [:id, :title, :elements, :created_at, :updated_at]))
    }

    {:ok, prepared} = Transfer.prepare(1, data)
    Transfer.merge(username, prepared)
  end

  defp titles(username), do: username |> Library.list() |> Enum.map(& &1.title)
end
