defmodule MDTClient.Diagrams.DiagramTest do
  use ExUnit.Case, async: true

  alias MDTClient.Diagrams.Diagram

  test "keeps the fields the editor knows and drops the rest" do
    [box] =
      Diagram.elements([
        %{
          "id" => "box",
          "type" => "rectangle",
          "x" => 10.123,
          "y" => -4,
          "width" => 120,
          "height" => -3,
          "text" => "Orders\r\nservice",
          "color" => "accent",
          "fill" => "tint",
          "stroke" => "wobbly",
          "size" => "l",
          "onclick" => "alert(1)"
        }
      ])

    assert box == %{
             "id" => "box",
             "type" => "rectangle",
             "x" => 10.12,
             "y" => -4,
             "width" => 120,
             "height" => 0,
             "text" => "Orders\nservice",
             "color" => "accent",
             "fill" => "tint",
             "stroke" => "solid",
             "size" => "l"
           }
  end

  test "drops elements it cannot draw, and repeated ids" do
    elements =
      Diagram.elements([
        %{"id" => "ok", "type" => "text"},
        %{"id" => "ok", "type" => "ellipse"},
        %{"id" => "bad id!", "type" => "text"},
        %{"id" => "star", "type" => "star"},
        "not a map"
      ])

    assert [%{"id" => "ok", "type" => "text", "color" => "ink", "size" => "m"}] = elements
    assert Diagram.elements("not a list") == []
  end

  test "arrows come loose from elements that are not there, or are arrows" do
    elements =
      Diagram.elements([
        %{"id" => "box", "type" => "rectangle"},
        %{"id" => "other", "type" => "arrow", "start" => "box"},
        %{"id" => "arrow", "type" => "arrow", "start" => "box", "end" => "gone"},
        %{"id" => "chain", "type" => "arrow", "start" => "other", "end" => "box"}
      ])

    assert %{"start" => "box", "end" => nil} = Enum.find(elements, &(&1["id"] == "arrow"))
    assert %{"start" => nil, "end" => "box"} = Enum.find(elements, &(&1["id"] == "chain"))
  end

  test "tables keep their rows, each cell on one line" do
    [table] =
      Diagram.elements([
        %{
          "id" => "users",
          "type" => "table",
          "text" => "users",
          "split" => 64.5,
          "rows" => [
            %{"id" => "r1", "type" => "uuid", "name" => "id", "extra" => true},
            %{"id" => "r2", "type" => "text", "name" => "first\nlast"},
            %{"id" => "r1", "type" => "again", "name" => "again"},
            %{"id" => "bad id!", "type" => "x", "name" => "y"},
            %{"type" => "no id"}
          ]
        }
      ])

    assert %{"type" => "table", "text" => "users", "split" => 64.5} = table

    assert table["rows"] == [
             %{"id" => "r1", "type" => "uuid", "name" => "id"},
             %{"id" => "r2", "type" => "text", "name" => "first last"}
           ]

    assert [%{"rows" => []}] =
             Diagram.elements([%{"id" => "t", "type" => "table", "rows" => "no"}])
  end

  test "arrows attach to rows of a table, or fall back to the whole table" do
    elements =
      Diagram.elements([
        %{"id" => "users", "type" => "table", "rows" => [%{"id" => "r1"}]},
        %{"id" => "box", "type" => "rectangle"},
        %{"id" => "row", "type" => "arrow", "start" => "users", "startRow" => "r1"},
        %{"id" => "gone", "type" => "arrow", "start" => "users", "startRow" => "r9"},
        %{"id" => "shape", "type" => "arrow", "end" => "box", "endRow" => "r1", "head" => "both"},
        %{
          "id" => "loose",
          "type" => "arrow",
          "start" => "nothing",
          "startRow" => "r1",
          "head" => "?"
        }
      ])

    by_id = Map.new(elements, &{&1["id"], &1})
    assert %{"start" => "users", "startRow" => "r1", "head" => "end"} = by_id["row"]
    assert %{"start" => "users", "startRow" => nil} = by_id["gone"]
    assert %{"end" => "box", "endRow" => nil, "head" => "both"} = by_id["shape"]
    assert %{"start" => nil, "startRow" => nil, "head" => "end"} = by_id["loose"]
  end

  test "a table's title and rows are searched and quoted" do
    diagram =
      Diagram.new(%{
        elements: [
          %{
            "id" => "orders",
            "type" => "table",
            "text" => "orders",
            "rows" => [%{"id" => "r1", "type" => "uuid", "name" => "customer_id"}]
          }
        ]
      })

    assert Diagram.texts(diagram) == ["orders", "uuid customer_id"]
    assert Diagram.matches?(diagram, Diagram.terms("orders CUSTOMER_ID"))
    assert Diagram.snippet(diagram, ["customer"]) == {"uuid ", "customer", "_id"}
  end

  test "a blank title becomes the default one" do
    assert Diagram.new(%{title: "  "}).title == Diagram.default_title()
    assert Diagram.new(%{title: "  Flow  "}).title == "Flow"
  end

  test "updating with what is already there changes nothing, not even the time" do
    diagram = Diagram.new(%{title: "Flow", elements: [%{"id" => "a", "type" => "text"}]})

    assert Diagram.update(diagram, %{title: "Flow", elements: diagram.elements}) == diagram

    updated = Diagram.update(diagram, %{title: "Flows"})
    assert updated.title == "Flows"
    assert DateTime.compare(updated.updated_at, diagram.updated_at) in [:gt, :eq]
    assert updated.search_text =~ "flows"
  end

  test "matches a search holding every word, wherever each was written" do
    diagram =
      Diagram.new(%{
        title: "Checkout",
        elements: [
          %{"id" => "a", "type" => "rectangle", "text" => "Payment  Gateway"},
          %{"id" => "b", "type" => "arrow", "text" => "retries"},
          %{"id" => "c", "type" => "text", "text" => "Owned by billing"}
        ]
      })

    assert Diagram.matches?(diagram, Diagram.terms("GATEWAY billing"))
    assert Diagram.matches?(diagram, Diagram.terms("payment gateway"))
    assert Diagram.matches?(diagram, Diagram.terms("checkout retries"))
    assert Diagram.matches?(diagram, [])
    refute Diagram.matches?(diagram, Diagram.terms("gateway shipping"))
  end

  test "snippets cut the text around the first match" do
    text = String.duplicate("lorem ", 10) <> "the Gateway " <> String.duplicate("ipsum ", 20)

    diagram =
      Diagram.new(%{
        title: "Gateway notes",
        elements: [%{"id" => "a", "type" => "text", "text" => text}]
      })

    assert Diagram.snippet(diagram, ["nothing"]) == nil
    assert {before, "Gateway", rest} = Diagram.snippet(diagram, ["gateway"])
    assert String.starts_with?(before, "…")
    assert String.ends_with?(before, "the ")
    assert String.ends_with?(rest, "…")

    assert Diagram.snippet(diagram, []) == nil
    assert Diagram.snippet(Diagram.new(%{title: "Gateway"}), ["gateway"]) == nil
  end
end
