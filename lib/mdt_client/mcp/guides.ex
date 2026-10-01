defmodule MDTClient.MCP.Guides do
  @moduledoc "Built-in agent guides available without repository or filesystem access."

  alias MDTClient.MCP.Catalogue

  @guides [
    {"notes", "Notes and search",
     "Markdown creation, finding existing notes and following paginated results."},
    {"diagrams", "Native diagram layout",
     "Shape sizing, table geometry, row attachments and complete native diagram examples."},
    {"http", "HTTP request samples",
     "Literal JSON/form bodies, headers, curl imports and the distinction between samples and sent history."}
  ]

  def list do
    for {slug, title, description} <- @guides do
      %{
        "uri" => "mdt://guides/#{slug}",
        "name" => "#{slug}-guide",
        "title" => title,
        "description" => description,
        "mimeType" => "text/markdown"
      }
    end
  end

  def read(uri) do
    if Enum.any?(list(), &(&1["uri"] == uri)) do
      {:ok, %{"uri" => uri, "mimeType" => "text/markdown", "text" => body(uri)}}
    else
      :error
    end
  end

  defp body("mdt://guides/notes") do
    """
    # Notes, search and pagination

    MDT is a local encrypted toolbox. All tools operate only on the identity
    associated with the Bearer token, while that identity is unlocked. You do
    not need repository access. Tools create, list and read; they do not edit,
    delete or mark notes complete. Every create call generates a new ID, so
    blindly repeating a successful call creates a duplicate.

    create_note takes title and Markdown body strings. Code fences, Unicode,
    task lists and empty bodies are supported. Returned url opens the note in
    MDT. Use get_note with its string id to read the complete saved content.

    ## Search

    list_notes searches titles and Markdown bodies; list_diagrams searches
    titles and all canvas text, including table cells and arrow labels. These
    searches are case-insensitive, normalize whitespace and require every
    query word to match somewhere in the item. Accents are not stripped.

    list_http_requests instead matches one normalized substring across the
    description, URL, tags, headers and body. Omit query or pass an empty
    string to list all items. List results are summaries, not complete bodies.

    ## Pagination

    All list tools take query, limit (1–100, default 20) and offset (default 0).
    Results contain items, total and next_offset. Keep query and limit fixed,
    then pass next_offset as offset until it is null. An offset past the end
    returns an empty items array. Results are newest first; concurrent edits
    can move entries between pages, so paginate while the collection is stable.

    ## Errors and readback

    A tool result with isError=true explains an invalid argument or missing
    item. Correct the input before retrying. Successful create/get results
    include structuredContent plus equivalent JSON text. Use list/get to
    inspect existing items and read back important creations.

    ## Example arguments
    """ <> examples("create_note") <> examples("list_notes")
  end

  defp body("mdt://guides/diagrams") do
    """
    # Native MDT diagrams

    create_diagram takes a title and an elements array. These are editable
    native shapes and arrows, not Mermaid source or raster images. Each call
    creates another diagram. Use list_diagrams/get_diagram to inspect an
    existing layout and follow returned url to open it in MDT.

    ## Coordinates and layout

    x runs right and y runs down, in canvas units. rectangle, ellipse, diamond,
    text and table require x, y, positive width and positive height. arrows
    require x1, y1, x2 and y2, even when endpoints are attached to elements.
    Every element needs an id unique within its diagram, using 1–64 ASCII
    letters, digits, underscores or hyphens.

    Start simple shapes around 220 × 80, put connected shapes about 380 units
    apart horizontally or 180 vertically, and leave extra room for arrow
    labels. Use short labels and explicit newlines. The editor grows shapes to
    fit wrapped labels, fits free text, and recalculates table columns/heights.
    These are starting dimensions rather than fixed text measurements.

    Styles: color=ink/accent/ok/warn/bad/violet, fill=none/tint,
    stroke=solid/dashed, size=s/m/l. Defaults: ink, none, solid, m.
    Arrow head=end/both/none; default end. Use head=none for plain lifelines.

    ## Attachments

    start/end reference existing non-arrow element IDs in the same diagram.
    Omit an attachment or pass null for a free endpoint. Arrow coordinates
    remain required; the editor resolves attached endpoints after layout.

    Tables contain rows with id, type and name strings. Row IDs must be unique
    within their table. type is the left column and name the right column;
    row text is single-line. startRow/endRow reference a row on the table
    named by start/end. Referencing a nonexistent element/row is rejected
    rather than silently detaching the arrow.

    ## Table sizing and row anchors

    | size | font | header height | row height |
    | --- | ---: | ---: | ---: |
    | s | 12 | 31 | 24 |
    | m | 14 | 36 | 28 |
    | l | 17 | 44 | 34 |

    height = header height + number of rows × row height.
    For zero-based row index i, its center is:
    y + header height + (i + 0.5) × row height.
    Horizontal anchors lie on the table's left or right edge, facing the other
    endpoint. A medium table with two rows has height 92; row centers are
    y+50 and y+78. Try width 260–320 and split 100 for short fields. The editor
    adjusts width and split to fit actual cells, so avoid treating them as
    permanent font measurements.

    ## Complete example arguments
    """ <> examples("create_diagram")
  end

  defp body("mdt://guides/http") do
    """
    # HTTP request samples

    create_http_request saves a sample without sending any network request.
    import_http_request parses a curl command without executing curl or a
    shell. Each call creates another item. The user can open the returned
    MDT url and manually send it in HTTP Client.

    url in the creation arguments is the absolute http:// or https:// API
    destination. In results, request_url is that API destination, while url
    opens the saved item in MDT. IDs are positive integers, unlike note and
    diagram IDs, which are strings.

    ## Method, body and headers

    Methods: GET, POST, PUT, PATCH, DELETE, HEAD, OPTIONS. Default GET.
    body is always literal text: serialize a JSON object yourself, or provide
    URL-encoded form text such as sku=A123&quantity=1. JSON syntax is not
    validated, allowing intentionally malformed samples for testing.

    body_type defaults to text. none discards the body; text, json and form
    preserve its literal text and supply Content-Type text/plain,
    application/json or application/x-www-form-urlencoded respectively.
    An explicit Content-Type is preserved. An empty body stores no payload.

    Input headers are name/value objects. Repeat a name for multiple values.
    Result headers are lowercase names mapped to arrays of values. Optional
    description and tags make a sample easier to find.

    ## Finding and inspecting

    list_http_requests includes unsent samples and existing request history.
    sent=false means an unsent sample; sent=true means a recorded send attempt,
    including one that failed. get_http_request returns the stored request,
    never response payloads, and never sends it. Search is a case-insensitive
    normalized substring across description, URL, tags, headers and body.
    Follow next_offset until null, keeping query and limit fixed.

    ## Example arguments
    """ <> examples("create_http_request") <> examples("import_http_request")
  end

  defp examples(name) do
    tool = Enum.find(Catalogue.list(), &(&1["name"] == name))

    Enum.map_join(tool["inputSchema"]["examples"], "\n", fn example ->
      "\n### #{name}\n\n```json\n#{Jason.encode!(example, pretty: true)}\n```\n"
    end)
  end
end
