defmodule MDTClient.Notes.TransferTest do
  use ExUnit.Case, async: true

  import MDTClient.VaultHelpers

  alias MDTClient.Notes.Library
  alias MDTClient.Notes.Note
  alias MDTClient.Notes.Transfer

  @fields [:id, :title, :body, :done_at, :created_at, :updated_at]

  setup do
    unlocked_identity()
  end

  test "merging adds notes that are new here", %{username: username} do
    mine = keep(username, note("Mine", ~U[2026-09-01 10:00:00.000001Z]))

    :ok = merge(username, [note("Theirs", ~U[2026-09-02 10:00:00.000001Z])])

    assert titles(username) == ["Theirs", "Mine"]
    assert {:ok, ^mine} = Library.get(username, mine.id)
  end

  test "a note both sides hold keeps the version changed last", %{username: username} do
    older = note("Plan", ~U[2026-09-01 10:00:00.000001Z])
    newer = %{older | title: "Plan v2", updated_at: ~U[2026-09-05 10:00:00.000001Z]}

    keep(username, newer)
    :ok = merge(username, [older])
    assert titles(username) == ["Plan v2"]
  end

  test "when the imported version wins, the version here is kept beside it", %{
    username: username
  } do
    mine = keep(username, note("Plan", ~U[2026-09-01 10:00:00.000001Z], "local edit"))

    theirs = %{
      mine
      | updated_at: ~U[2026-09-05 10:00:00.000001Z],
        body: "remote edit",
        done_at: ~U[2026-09-05 10:00:00.000001Z]
    }

    :ok = merge(username, [theirs])

    assert {:ok, %{body: "remote edit", done_at: %DateTime{}}} = Library.get(username, mine.id)
    assert titles(username) == ["Plan", "Plan (before import)"]
    assert [%{id: kept}] = Library.list(username, "local")
    assert %{^kept => {_, "local", _}} = Library.snippets(username, [kept], "local")

    # Merging the same file again finds the copy already kept.
    :ok = merge(username, [theirs])
    assert length(Library.list(username)) == 2
  end

  test "an identical version changed later elsewhere just replaces this one", %{
    username: username
  } do
    mine = keep(username, note("Plan", ~U[2026-09-01 10:00:00.000001Z]))

    :ok = merge(username, [%{mine | updated_at: ~U[2026-09-05 10:00:00.000001Z]}])

    assert titles(username) == ["Plan"]
  end

  test "merging this identity's own export changes nothing", %{username: username} do
    keep(username, note("One", ~U[2026-09-01 10:00:00.000001Z]))
    keep(username, %{note("Two", ~U[2026-09-02 10:00:00.000001Z]) | done_at: DateTime.utc_now()})
    before = Library.all(username)

    {:ok, own} = Transfer.export(username)
    {:ok, own} = Transfer.prepare(1, own)
    :ok = Transfer.merge(username, own)

    assert Library.all(username) == before
  end

  test "replacing drops what is here", %{username: username} do
    keep(username, note("Mine", ~U[2026-09-01 10:00:00.000001Z]))

    :ok = Transfer.replace(username, [note("Theirs", DateTime.utc_now())])

    assert titles(username) == ["Theirs"]
  end

  test "exports plain maps and rebuilds the search text on the way in", %{username: username} do
    keep(username, note("Plan", ~U[2026-09-01 10:00:00.000001Z], "Gateway"))

    {:ok, %{notes: [exported]}} = Transfer.export(username)
    refute is_struct(exported)
    refute Map.has_key?(exported, :search_text)

    {:ok, [prepared]} = Transfer.prepare(1, %{notes: [exported]})
    assert prepared.search_text =~ "gateway"
    assert Transfer.describe([prepared]) == "1 note"
  end

  test "a damaged section is refused whole" do
    good = Map.take(note("Ok", DateTime.utc_now()), @fields)

    assert {:error, _reason} = Transfer.prepare(1, %{notes: [good, %{id: "x"}]})
    assert {:error, _reason} = Transfer.prepare(1, %{notes: [%{good | id: "../x"}]})
    assert {:error, _reason} = Transfer.prepare(1, %{notes: [%{good | done_at: "yesterday"}]})
    assert {:error, _reason} = Transfer.prepare(1, :nonsense)
    assert Transfer.describe([]) == "No notes"
  end

  defp note(title, at, body \\ "Body") do
    Note.new(%{title: title, body: body, created_at: at, updated_at: at})
  end

  # Straight into the library, timestamps and all.
  defp keep(username, note) do
    :ok = Library.rewrite(username, &(&1 ++ [note]))
    note
  end

  defp merge(username, notes) do
    {:ok, prepared} = Transfer.prepare(1, %{notes: Enum.map(notes, &Map.take(&1, @fields))})
    Transfer.merge(username, prepared)
  end

  defp titles(username), do: username |> Library.list() |> Enum.map(& &1.title)
end
