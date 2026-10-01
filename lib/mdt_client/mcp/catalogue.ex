defmodule MDTClient.MCP.Catalogue do
  @moduledoc "Self-contained tool descriptions, examples and input/output contracts."

  alias MDTClient.HttpClient.Utils

  def list do
    [
      tool(
        "create_note",
        "Create note",
        "Save a new Markdown note. Returns its generated ID, full body and URL to open in MDT. " <>
          "Each call creates another note; this does not update or complete an existing note.",
        object(
          %{
            "title" => title(),
            "body" =>
              describe(
                string(100_000),
                "Markdown source, including code fences and task lists. May be empty."
              )
          },
          ["title", "body"]
        )
        |> examples([
          %{
            "title" => "Release checklist",
            "body" => "## Before release\n\n- [ ] Verify checkout\n- [x] Document API"
          }
        ]),
        note_result(),
        false
      ),
      tool(
        "list_notes",
        "Find notes",
        "List notes, newest updated first. Search is case-insensitive and matches every query word " <>
          "across titles and Markdown bodies. Returns summaries; use get_note for the full body. " <>
          paging(),
        listing("Words to find anywhere in the title or body; all words must match."),
        page_result(note_summary()),
        true
      ),
      tool(
        "get_note",
        "Read note",
        "Read a note's complete Markdown body and metadata using an ID returned by list_notes or create_note.",
        identified("Note ID returned by list_notes or create_note."),
        note_result(),
        true
      ),
      tool(
        "create_diagram",
        "Create diagram",
        "Create an editable native MDT canvas diagram, not Mermaid or an image. Supply a complete layout. " <>
          "Shapes need x/y and positive width/height; arrows need x1/y1/x2/y2 even when attached. " <>
          "IDs must be unique within the diagram. start/end attach to shapes; startRow/endRow attach to rows on those tables. " <>
          "Leave room for labels and use short multiline text. The editor fits text and table cells when opened. " <>
          "Read mdt://guides/diagrams for sizing, row anchors and examples. Each call creates a new diagram.",
        object(
          %{
            "title" => title(),
            "elements" =>
              describe(
                array(element(), 5_000),
                "Native editable elements in drawing order. Empty creates a blank canvas; include shapes before their arrows for readability."
              )
          },
          ["title", "elements"]
        )
        |> examples(diagram_examples()),
        diagram_result(),
        false
      ),
      tool(
        "list_diagrams",
        "Find diagrams",
        "List diagrams, newest updated first. Search is case-insensitive and matches every word across " <>
          "the title, shape text, arrow labels, table titles and table cells. Use get_diagram to inspect native elements. " <>
          paging(),
        listing(
          "Words to find across diagram titles and canvas text, including table cells; all words must match."
        ),
        page_result(diagram_summary()),
        true
      ),
      tool(
        "get_diagram",
        "Read diagram",
        "Read a diagram's full native editable elements, coordinates, styles and row attachments. " <>
          "Use an ID returned by list_diagrams or create_diagram; returned elements can also guide a new diagram.",
        identified("Diagram ID returned by list_diagrams or create_diagram."),
        diagram_result(),
        true
      ),
      tool(
        "create_http_request",
        "Save HTTP sample",
        "Save an HTTP request sample without sending it. The user can open its returned MDT URL and send it in HTTP Client. " <>
          "Returns sent=false and no response. Specify body_type for the intended Content-Type; body is always a string. " <>
          "Each call creates another sample. Read mdt://guides/http for JSON, form and header examples.",
        request_schema(),
        request_result(),
        false
      ),
      tool(
        "import_http_request",
        "Import curl sample",
        "Parse a curl command and save an HTTP sample without running curl, a shell or a network request. " <>
          "Returns the parsed method, URL, headers, body and sent=false. Each call creates another sample.",
        object(
          %{
            "curl" =>
              describe(
                string(100_000, 1),
                "A curl command as text; quote arguments as in a shell. Parsing never executes the command."
              ),
            "description" => describe(title(), "Optional human-readable sample description."),
            "tags" => tags()
          },
          ["curl"]
        )
        |> examples([
          %{
            "curl" =>
              "curl -X POST 'https://api.example.test/orders' -H 'Content-Type: application/json' --data-raw '{\"sku\":\"A123\",\"quantity\":1}'",
            "description" => "Create an order",
            "tags" => ["orders", "sample"]
          }
        ]),
        request_result(),
        false
      ),
      tool(
        "list_http_requests",
        "Find HTTP requests",
        "List saved HTTP samples and sent request history, newest saved first. Search matches a case-insensitive " <>
          "normalized substring across description, URL, tags, headers and body. This differs from note/diagram word matching. " <>
          "sent=false identifies samples; sent=true identifies attempted requests, including failed sends. " <>
          paging(),
        listing(
          "Case-insensitive substring to find in description, URL, tags, headers or body; whitespace is normalized."
        ),
        page_result(request_summary()),
        true
      ),
      tool(
        "get_http_request",
        "Read HTTP request",
        "Read a stored request's method, URL, headers and body. Does not send it or return response payloads. " <>
          "request_url is the API destination; url opens the saved item in MDT. Headers are returned as lowercase names mapped to arrays of values.",
        object(
          %{
            "id" =>
              describe(
                %{"type" => "integer", "minimum" => 1},
                "Numeric request ID returned by a create/import/list tool; do not convert it to a string."
              )
          },
          ["id"]
        )
        |> examples([%{"id" => 1}]),
        request_result(),
        true
      )
    ]
  end

  defp tool(name, title, description, input, output, read?) do
    %{
      "name" => name,
      "title" => title,
      "description" => description,
      "inputSchema" => input,
      "outputSchema" => output,
      "annotations" => %{
        "readOnlyHint" => read?,
        "destructiveHint" => false,
        "idempotentHint" => read?,
        "openWorldHint" => false
      }
    }
  end

  defp paging do
    "Omit query or use an empty string to list all. Default limit=20, offset=0. " <>
      "Pass next_offset as offset with the same query and limit until next_offset is null."
  end

  defp listing(query_description) do
    object(
      %{
        "query" => string(1_000) |> describe(query_description) |> default(""),
        "limit" =>
          %{"type" => "integer", "minimum" => 1, "maximum" => 100}
          |> describe("Maximum items per page, from 1 to 100.")
          |> default(20),
        "offset" =>
          %{"type" => "integer", "minimum" => 0}
          |> describe(
            "Zero-based offset. For the next page use the previous result's next_offset; null means finished."
          )
          |> default(0)
      },
      []
    )
    |> examples([%{"query" => "", "limit" => 5, "offset" => 0}])
  end

  defp identified(description) do
    object(%{"id" => describe(identifier(), description)}, ["id"])
    |> examples([%{"id" => "example_item_id"}])
  end

  defp title,
    do:
      describe(
        string(200, 1),
        "Human-readable title, up to 200 characters. Whitespace is trimmed."
      )

  defp tags,
    do:
      array(string(200), 50)
      |> describe("Up to 50 searchable tags, each up to 200 characters.")
      |> default([])

  defp identifier, do: string(64, 1) |> Map.put("pattern", "^[A-Za-z0-9_-]+$")
  defp string(max, min \\ 0), do: %{"type" => "string", "maxLength" => max, "minLength" => min}
  defp text, do: %{"type" => "string"}
  defp boolean, do: %{"type" => "boolean"}
  defp integer, do: %{"type" => "integer", "minimum" => 0}
  defp array(items, max \\ 5_000), do: %{"type" => "array", "items" => items, "maxItems" => max}
  defp choice(values), do: %{"type" => "string", "enum" => values}
  defp nullable(schema), do: Map.update!(schema, "type", &[&1, "null"])
  defp describe(schema, description), do: Map.put(schema, "description", description)
  defp default(schema, value), do: Map.put(schema, "default", value)
  defp examples(schema, values), do: Map.put(schema, "examples", values)

  defp object(properties, required) do
    %{
      "type" => "object",
      "properties" => properties,
      "required" => required,
      "additionalProperties" => false
    }
  end

  defp record(properties), do: object(properties, Map.keys(properties))
  defp coordinate, do: %{"type" => "number", "minimum" => -10_000_000, "maximum" => 10_000_000}
  defp extent, do: %{"type" => "number", "minimum" => 0, "maximum" => 10_000_000}

  defp element(stored? \\ false) do
    properties = %{
      "id" =>
        describe(
          identifier(),
          "Unique element ID within this diagram: 1–64 ASCII letters, digits, underscores or hyphens."
        ),
      "type" =>
        describe(
          choice(~w(rectangle ellipse diamond text table arrow)),
          "Native element kind. Shapes/text/tables use a bounding box; arrows use endpoint coordinates."
        ),
      "text" =>
        string(10_000)
        |> describe(
          "Shape label, free text, arrow label or table title. Use newline characters for multiline labels."
        )
        |> default(""),
      "x" => describe(coordinate(), "Left edge of a shape, text or table, in canvas units."),
      "y" =>
        describe(
          coordinate(),
          "Top edge of a shape, text or table. Positive y runs down the canvas."
        ),
      "width" =>
        describe(
          extent(),
          "Bounding-box width. Creation requires a positive value; 220 is a useful starting width for a short shape label."
        ),
      "height" =>
        describe(
          extent(),
          "Bounding-box height. Creation requires a positive value; 80 is a useful starting height. Table heights are recalculated from row count in the editor."
        ),
      "x1" =>
        describe(coordinate(), "Arrow start x coordinate; required even when start is attached."),
      "y1" =>
        describe(coordinate(), "Arrow start y coordinate; required even when start is attached."),
      "x2" =>
        describe(coordinate(), "Arrow end x coordinate; required even when end is attached."),
      "y2" =>
        describe(coordinate(), "Arrow end y coordinate; required even when end is attached."),
      "split" =>
        extent()
        |> describe(
          "Table type-column width from its left edge. A starting value of 100 is useful; the editor fits columns to their contents."
        )
        |> default(0),
      "start" =>
        nullable(identifier())
        |> describe(
          "ID of the non-arrow element attached to the arrow start. Omit or use null for an unattached endpoint."
        )
        |> default(nil),
      "end" =>
        nullable(identifier())
        |> describe(
          "ID of the non-arrow element attached to the arrow end. Omit or use null for an unattached endpoint."
        )
        |> default(nil),
      "startRow" =>
        nullable(identifier())
        |> describe(
          "Row ID on the table named by start. Requires a non-null start referencing that table."
        )
        |> default(nil),
      "endRow" =>
        nullable(identifier())
        |> describe(
          "Row ID on the table named by end. Requires a non-null end referencing that table."
        )
        |> default(nil),
      "head" =>
        choice(~w(end both none))
        |> describe("Arrowhead placement. Use none for plain lines or dashed sequence lifelines.")
        |> default("end"),
      "color" =>
        choice(~w(ink accent ok warn bad violet))
        |> describe(
          "Theme-aware semantic color: ink, accent, success (ok), warning (warn), error (bad) or violet."
        )
        |> default("ink"),
      "fill" =>
        choice(~w(none tint))
        |> describe("Shape/table fill: none for outline only; tint for a subtle color fill.")
        |> default("none"),
      "stroke" =>
        choice(~w(solid dashed))
        |> describe("Solid or dashed outline/arrow stroke.")
        |> default("solid"),
      "size" =>
        choice(~w(s m l))
        |> describe(
          "Text size preset. Table font/header/row sizes in canvas units: s=12/31/24, m=14/36/28, l=17/44/34. Table height = header + row count × row height."
        )
        |> default("m"),
      "rows" =>
        array(row(), 500)
        |> describe(
          "Table rows in display order. Row IDs must be unique within this table; type and name are single-line strings. Row center y = table y + header height + (index + 0.5) × row height."
        )
        |> default([])
    }

    conditions = [
      %{
        "if" => %{"properties" => %{"type" => %{"const" => "arrow"}}, "required" => ["type"]},
        "then" => %{"required" => ~w(x1 y1 x2 y2)},
        "else" => box_requirements(stored?)
      }
    ]

    conditions =
      if stored? do
        conditions
      else
        conditions ++
          Enum.map([{"startRow", "start"}, {"endRow", "end"}], fn {row, endpoint} ->
            %{
              "if" => %{"properties" => %{row => text()}, "required" => [row]},
              "then" => %{"properties" => %{endpoint => identifier()}, "required" => [endpoint]}
            }
          end)
      end

    object(properties, ["id", "type"])
    |> Map.put("allOf", conditions)
  end

  defp box_requirements(true), do: %{"required" => ~w(x y width height)}

  defp box_requirements(false) do
    %{
      "required" => ~w(x y width height),
      "properties" => %{
        "width" => %{"exclusiveMinimum" => 0},
        "height" => %{"exclusiveMinimum" => 0}
      }
    }
  end

  defp row do
    object(
      %{
        "id" =>
          describe(identifier(), "Stable row ID for arrow attachments; unique within its table."),
        "type" =>
          describe(
            string(200),
            "Left column, usually a data type such as uuid or text; may be empty."
          ),
        "name" =>
          describe(
            string(200),
            "Right column, usually a field name such as customer_id; may be empty."
          )
      },
      ["id", "type", "name"]
    )
  end

  defp request_schema do
    object(
      %{
        "url" =>
          describe(
            string(8_000, 1),
            "Absolute http:// or https:// request destination, including any query string. This endpoint is saved, never contacted by the tool."
          ),
        "method" => choice(Utils.methods()) |> describe("HTTP method to save.") |> default("GET"),
        "description" => describe(title(), "Optional human-readable sample description."),
        "tags" => tags(),
        "headers" =>
          array(
            object(
              %{
                "name" =>
                  describe(
                    string(200, 1),
                    "HTTP header name, for example Content-Type or Authorization."
                  ),
                "value" =>
                  describe(
                    string(8_000),
                    "Literal header value. Repeat a name in another row for multiple values."
                  )
              },
              ["name", "value"]
            ),
            100
          )
          |> describe(
            "Header rows as name/value objects. Explicit Content-Type takes precedence over body_type's default."
          )
          |> default([]),
        "body" =>
          string(100_000)
          |> describe(
            "Literal body text, not a JSON object. For json pass a serialized JSON string; for form pass URL-encoded text such as sku=A123&quantity=1. JSON syntax is not validated, so malformed-body test samples are allowed."
          )
          |> default(""),
        "body_type" =>
          choice(~w(none text json form))
          |> describe(
            "none discards the body; text/json/form preserve literal body text and default Content-Type to text/plain, application/json or application/x-www-form-urlencoded. An explicit Content-Type header is preserved."
          )
          |> default("text")
      },
      ["url"]
    )
    |> examples([
      %{
        "url" => "https://api.example.test/products?limit=20",
        "method" => "GET",
        "body_type" => "none",
        "description" => "Browse products"
      },
      %{
        "url" => "https://api.example.test/orders",
        "method" => "POST",
        "body_type" => "json",
        "body" => "{\"sku\":\"A123\",\"quantity\":1}",
        "description" => "Create an order",
        "tags" => ["orders", "sample"]
      },
      %{
        "url" => "https://api.example.test/oauth/token",
        "method" => "POST",
        "body_type" => "form",
        "body" => "grant_type=client_credentials&client_id=local-demo",
        "description" => "Local token sample"
      }
    ])
  end

  defp item_links do
    %{
      "path" => describe(text(), "Relative MDT path to open the saved item."),
      "url" =>
        describe(text(), "Absolute URL to open this item in MDT, not an API request destination.")
    }
  end

  defp note_summary do
    record(%{
      "id" => identifier(),
      "title" => text(),
      "excerpt" => text(),
      "done" => boolean(),
      "updated_at" => timestamp()
    })
  end

  defp note_result do
    record(
      Map.merge(item_links(), %{
        "id" => identifier(),
        "title" => text(),
        "body" => text(),
        "done" => boolean(),
        "created_at" => timestamp(),
        "updated_at" => timestamp()
      })
    )
  end

  defp diagram_summary do
    record(%{
      "id" => identifier(),
      "title" => text(),
      "element_count" => integer(),
      "updated_at" => timestamp()
    })
  end

  defp diagram_result do
    record(
      Map.merge(item_links(), %{
        "id" => identifier(),
        "title" => text(),
        "elements" => array(element(true)),
        "created_at" => timestamp(),
        "updated_at" => timestamp()
      })
    )
  end

  defp request_summary do
    record(%{
      "id" => %{"type" => "integer", "minimum" => 1},
      "description" => nullable(text()),
      "tags" => array(text(), 50),
      "method" => choice(Utils.methods()),
      "request_url" =>
        describe(text(), "API request destination, distinct from an MDT item URL."),
      "sent" =>
        describe(
          boolean(),
          "false for an unsent sample; true for a request with a recorded send attempt, including errors."
        ),
      "saved_at" => timestamp()
    })
  end

  defp request_result do
    request_summary()["properties"]
    |> Map.merge(item_links())
    |> Map.merge(%{
      "headers" =>
        describe(
          %{"type" => "object", "additionalProperties" => array(text())},
          "Lowercase header names mapped to arrays of values; this differs from the input's name/value rows."
        ),
      "body" =>
        describe(
          text(),
          "Stored literal request body, or an empty string when absent. Response bodies are never included."
        )
    })
    |> record()
  end

  defp page_result(item) do
    record(%{
      "items" =>
        describe(
          array(item, 100),
          "This page's summaries; use the relevant get tool for complete content."
        ),
      "total" => describe(integer(), "Total matching items across all pages."),
      "next_offset" =>
        describe(
          nullable(integer()),
          "Offset for the next page. null means there are no more matching items."
        )
    })
  end

  defp timestamp,
    do: describe(Map.put(text(), "format", "date-time"), "UTC timestamp in RFC 3339 format.")

  defp diagram_examples do
    [
      %{
        "title" => "Checkout flow",
        "elements" => [
          %{
            "id" => "client",
            "type" => "rectangle",
            "x" => 40,
            "y" => 100,
            "width" => 220,
            "height" => 80,
            "text" => "Browser",
            "color" => "accent",
            "fill" => "tint"
          },
          %{
            "id" => "api",
            "type" => "rectangle",
            "x" => 420,
            "y" => 100,
            "width" => 220,
            "height" => 80,
            "text" => "Checkout API",
            "color" => "ok",
            "fill" => "tint"
          },
          %{
            "id" => "submit",
            "type" => "arrow",
            "x1" => 260,
            "y1" => 140,
            "x2" => 420,
            "y2" => 140,
            "start" => "client",
            "end" => "api",
            "text" => "POST /checkout",
            "head" => "end"
          }
        ]
      },
      %{
        "title" => "Customer order schema",
        "elements" => [
          %{
            "id" => "customers",
            "type" => "table",
            "x" => 40,
            "y" => 120,
            "width" => 260,
            "height" => 92,
            "split" => 100,
            "size" => "m",
            "text" => "customers",
            "rows" => [
              %{"id" => "customer_pk", "type" => "uuid", "name" => "id (PK)"},
              %{"id" => "customer_email", "type" => "text", "name" => "email"}
            ]
          },
          %{
            "id" => "orders",
            "type" => "table",
            "x" => 480,
            "y" => 120,
            "width" => 280,
            "height" => 92,
            "split" => 100,
            "size" => "m",
            "text" => "orders",
            "rows" => [
              %{"id" => "order_pk", "type" => "uuid", "name" => "id (PK)"},
              %{"id" => "order_customer_fk", "type" => "uuid", "name" => "customer_id (FK)"}
            ]
          },
          %{
            "id" => "customer_relation",
            "type" => "arrow",
            "x1" => 480,
            "y1" => 198,
            "x2" => 300,
            "y2" => 170,
            "start" => "orders",
            "startRow" => "order_customer_fk",
            "end" => "customers",
            "endRow" => "customer_pk",
            "text" => "many : 1"
          }
        ]
      }
    ]
  end
end
