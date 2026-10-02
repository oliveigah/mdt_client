defmodule MDTClientWeb.PanelComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias MDTClientWeb.PanelComponents

  defp groups do
    [{"Today", "today", [1, 2, 3]}, {"Yesterday", "yesterday", [4, 5]}, {"Older", "older", [6]}]
  end

  describe "window/3" do
    test "keeps every row when they fit" do
      assert PanelComponents.window(groups(), MapSet.new(), 10) ==
               {[
                  {"Today", "today", 3, [1, 2, 3]},
                  {"Yesterday", "yesterday", 2, [4, 5]},
                  {"Older", "older", 1, [6]}
                ], 0}
    end

    test "cuts at the limit, counting whole groups and what was left out" do
      assert PanelComponents.window(groups(), MapSet.new(), 4) ==
               {[{"Today", "today", 3, [1, 2, 3]}, {"Yesterday", "yesterday", 2, [4]}], 2}
    end

    test "leaves out a group none of whose rows fit, rather than an empty header" do
      assert PanelComponents.window(groups(), MapSet.new(), 3) ==
               {[{"Today", "today", 3, [1, 2, 3]}], 3}
    end

    test "a collapsed group shows its header and takes none of the limit" do
      assert PanelComponents.window(groups(), MapSet.new(["today"]), 2) ==
               {[{"Today", "today", 3, []}, {"Yesterday", "yesterday", 2, [4, 5]}], 1}

      # Nor does it count as left out once the list is cut before it.
      assert PanelComponents.window(groups(), MapSet.new(["older"]), 2) ==
               {[{"Today", "today", 3, [1, 2]}], 3}
    end

    test "a collapsed group right after the last row that fits still shows" do
      assert PanelComponents.window(groups(), MapSet.new(["yesterday"]), 3) ==
               {[{"Today", "today", 3, [1, 2, 3]}, {"Yesterday", "yesterday", 2, []}], 1}
    end
  end

  describe "load_more/1" do
    test "says how many rows are left and asks for more" do
      document =
        (&PanelComponents.load_more/1)
        |> render_component(id: "more", list: "rows", hidden: 12)
        |> LazyHTML.from_fragment()

      assert document
             |> LazyHTML.query("#more[phx-click=load_more][data-list=rows]")
             |> Enum.count() == 1

      assert LazyHTML.text(document) =~ "12 more"
    end

    test "renders nothing once every row is shown" do
      html = render_component(&PanelComponents.load_more/1, id: "more", list: "rows", hidden: 0)

      refute html =~ "more"
    end
  end
end
