defmodule MDTClientWeb.GitLive.Graph.LayoutTest do
  use ExUnit.Case, async: true

  alias MDTClient.Git.Commit
  alias MDTClientWeb.GitLive.Graph.Layout

  defp commit(id, parents) do
    %Commit{
      id: id,
      parents: parents,
      author_name: "Ada",
      author_email: "ada@example.test",
      authored_at: ~U[2026-01-01 00:00:00Z],
      committer_name: "Ada",
      committer_email: "ada@example.test",
      committed_at: ~U[2026-01-01 00:00:00Z],
      summary: id,
      body: "",
      signature_status: :no_signature,
      labels: []
    }
  end

  defp lanes(layout), do: Map.new(layout.rows, &{&1.commit.id, &1.lane})

  defp row(layout, id), do: Enum.find(layout.rows, &(&1.commit.id == id))

  test "an empty history lays out nothing" do
    assert %Layout{rows: [], lane_count: 0} = Layout.layout([])
  end

  test "a linear history stays in one lane" do
    layout = Layout.layout([commit("c", ["b"]), commit("b", ["a"]), commit("a", [])])

    assert layout.lane_count == 1
    assert lanes(layout) == %{"a" => 0, "b" => 0, "c" => 0}
    assert Enum.all?(layout.rows, &(&1.through == []))
    assert row(layout, "c").incoming == []
    assert row(layout, "c").outgoing == [{0, 0, 0}]
    assert row(layout, "b").incoming == [{0, 0, 0}]
    assert row(layout, "a").outgoing == []
  end

  test "a merge fans out to a second lane and rejoins at the shared parent" do
    layout =
      Layout.layout([
        commit("merge", ["main", "side"]),
        commit("main", ["base"]),
        commit("side", ["base"]),
        commit("base", [])
      ])

    assert layout.lane_count == 2
    assert lanes(layout) == %{"merge" => 0, "main" => 0, "side" => 1, "base" => 0}

    # The first parent continues the merge lane, the second opens a new one.
    assert row(layout, "merge").outgoing == [{0, 0, 0}, {0, 1, 1}]

    # The side branch crosses back into the lane already reserved for "base".
    assert row(layout, "side").outgoing == [{1, 0, 0}]
    assert row(layout, "base").incoming == [{0, 0, 0}]

    # While "main" is drawn, the side lane keeps running down the row.
    assert row(layout, "main").through == [{1, 1, 1}]
    assert row(layout, "side").through == [{0, 0, 0}]
  end

  test "an octopus merge opens one lane per extra parent" do
    layout =
      Layout.layout([
        commit("octopus", ["a", "b", "c"]),
        commit("a", []),
        commit("b", []),
        commit("c", [])
      ])

    assert layout.lane_count == 3
    assert row(layout, "octopus").outgoing == [{0, 0, 0}, {0, 1, 1}, {0, 2, 2}]
    assert lanes(layout) == %{"octopus" => 0, "a" => 0, "b" => 1, "c" => 2}
  end

  test "several roots reuse lanes that earlier histories freed" do
    layout =
      Layout.layout([
        commit("first", []),
        commit("second", []),
        commit("third", [])
      ])

    assert layout.lane_count == 1
    assert lanes(layout) == %{"first" => 0, "second" => 0, "third" => 0}
    assert Enum.all?(layout.rows, &(&1.incoming == [] and &1.outgoing == []))
  end

  test "two independent histories are laid out side by side until each root ends" do
    layout =
      Layout.layout([
        commit("a2", ["a1"]),
        commit("b2", ["b1"]),
        commit("a1", []),
        commit("b1", [])
      ])

    assert layout.lane_count == 2
    assert lanes(layout) == %{"a2" => 0, "b2" => 1, "a1" => 0, "b1" => 1}
    assert row(layout, "b2").through == [{0, 0, 0}]
    assert row(layout, "a1").through == [{1, 1, 1}]
    # The first history ends, so the lane is free again but nothing claims it.
    assert row(layout, "b1").through == []
  end

  test "a commit whose parents fall outside the window keeps its lane reserved" do
    layout = Layout.layout([commit("tip", ["truncated"])])

    assert layout.lane_count == 1
    assert row(layout, "tip").outgoing == [{0, 0, 0}]
  end

  test "lanes and colors are deterministic for the same history" do
    commits = [
      commit("merge", ["main", "side"]),
      commit("main", ["base"]),
      commit("side", ["base"]),
      commit("base", [])
    ]

    assert Layout.layout(commits) == Layout.layout(commits)
  end

  test "colors cycle with the lane index" do
    commits = [
      commit("octopus", Enum.map(1..10, &"p#{&1}")) | Enum.map(1..10, &commit("p#{&1}", []))
    ]

    layout = Layout.layout(commits)

    assert layout.lane_count == 10
    assert row(layout, "p9").color == rem(8, Layout.colors())
    assert row(layout, "p1").color == 0
  end
end
