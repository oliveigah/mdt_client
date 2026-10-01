# MDT MCP integration

MDT exposes its existing encrypted note, diagram, and HTTP request stores to
agents through `/mcp` on the running Phoenix server. The desktop release uses
`http://127.0.0.1:12995/mcp`; development normally uses port `4000`. The
**Connect an agent** screen shows the URL for the running instance.

## Connection

1. Open MDT and unlock the local identity you want the agent to use.
2. Open **Connect an agent** and click **Enable agent access**.
3. Configure a client running on this machine for **Streamable HTTP**, using
   the displayed URL and `Authorization: Bearer <token>`.
4. Ask the agent to save a diagram, note, or HTTP request sample in MDT.

For clients that use an `mcpServers` configuration, the connection looks like
this. Client configuration formats vary; the screen generates the actual URL
and token, and clients with a settings UI can use those two values directly.

```json
{
  "mcpServers": {
    "mdt": {
      "type": "http",
      "url": "http://127.0.0.1:12995/mcp",
      "headers": {
        "Authorization": "Bearer <token from MDT>"
      }
    }
  }
}
```

The token grants creation, search, and reading in one identity. It is separate
from the browser session and never contains the vault password or encryption
key. MDT saves only its hash, encrypted inside the local identity's directory.
The token has no expiry and persists across restarts. Locking or closing MDT
pauses tool access; the same token works again after unlocking that identity,
so the agent's configuration does not need to change. Only rotating the token
or disabling access invalidates it. Revocation and rotation are saved
immediately, so old tokens stay invalid after restarting.
The token is shown only when generated; revisiting the screen offers rotation
if you need to copy a credential again.

## Tools

| Tool | Purpose | Required arguments |
| --- | --- | --- |
| `create_note` | Save a Markdown idea or task | `title`, `body` |
| `list_notes` | Search titles and bodies | None |
| `get_note` | Read the full note | String `id` |
| `create_diagram` | Save editable native canvas elements | `title`, `elements` |
| `list_diagrams` | Search text anywhere in diagrams | None |
| `get_diagram` | Read its elements and layout | String `id` |
| `create_http_request` | Save an HTTP sample without sending it | `url` |
| `import_http_request` | Parse and save a curl command without executing it | `curl` |
| `list_http_requests` | Search HTTP samples and existing request history | None |
| `get_http_request` | Read the saved request | Integer `id` |

All list tools accept `query`, `limit` (1–100, default 20), and `offset`
(default 0). Results contain `items`, `total`, and `next_offset`; pass
`next_offset` as the next call's `offset` until it is null. Results follow each
tool's existing search behavior. Note and diagram search match every word;
HTTP search matches a normalized substring.

Create/get results include the persisted item and an absolute `url` that
opens it in MDT. Each tool publishes a JSON Schema through `tools/list`;
inputs are validated before saving. Domain errors return `isError: true`
with a useful message so an agent can correct its call. Unknown methods and
tools return JSON-RPC errors.

The initial tools create new items with generated IDs. Repeating a create
call creates another item. Agents can read and search existing work; editing,
deletion, Git operations, and HTTP execution are not exposed by this catalogue.

## Agent discovery without source access

The server supplies its usage contract over MCP. A client does not need this
repository or a separate skill to use MDT:

1. `initialize` returns instructions describing the identity boundary,
   available actions, duplicate creation, search and pagination.
2. `tools/list` returns human-readable tool titles, field descriptions,
   defaults, complete example arguments, input schemas and output schemas.
3. `resources/list` discovers built-in Markdown guides. Use `resources/read`
   with one of their exact URIs for detailed guidance and working examples.
4. `tools/call` validates the advertised input contract before saving.
   Successful results follow the advertised output contract and include both
   `structuredContent` and equivalent JSON text. Tool errors use
   `isError: true`; their content explains which input to correct.

| Guide URI | Contents |
| --- | --- |
| `mdt://guides/notes` | Markdown examples, search semantics, pagination and readback |
| `mdt://guides/diagrams` | Layout, table sizing, row anchors and attached-arrow examples |
| `mdt://guides/http` | JSON/form bodies, headers, curl imports and saved samples |

For example, this JSON-RPC request reads the diagram guide:

```json
{
  "jsonrpc": "2.0",
  "id": 2,
  "method": "resources/read",
  "params": {"uri": "mdt://guides/diagrams"}
}
```

Guides are bundled with the application, use the same authenticated local
transport, and expose no arbitrary files or identity data. They do not support
subscriptions. `resources/templates/list` returns an empty list. Invalid
guide URIs return resource-not-found (`-32002`) rather than reading a path.

For clients that expose only tools to their model, the descriptions and input
schemas still include essential instructions and examples. The guides add
detail without requiring every client to load all of it into context.

List results are summaries; use a get tool for complete content. In HTTP
results, `request_url` is the API destination while `url` opens the item in
MDT. Input headers are name/value rows; output headers are lowercase names
mapped to arrays of values. `sent: true` means a recorded send attempt,
including a failed attempt, rather than a successful response.

## Examples

These are `arguments` for `tools/call`, not complete JSON-RPC envelopes.

### Notes

```json
{
  "title": "Keep API examples close to the code",
  "body": "## Idea\nSave a sample request for every endpoint.\n\n- [ ] Add authentication examples\n- [ ] Add error cases"
}
```

### Diagrams

Diagrams use MDT's canvas format and remain editable in its diagram editor.
An agent supplies the layout and text. This checkout example can be passed to
`create_diagram`:

```json
{
  "title": "Checkout flow",
  "elements": [
    {
      "id": "client",
      "type": "rectangle",
      "x": 40,
      "y": 80,
      "width": 180,
      "height": 80,
      "text": "Browser",
      "color": "accent",
      "fill": "tint"
    },
    {
      "id": "api",
      "type": "rectangle",
      "x": 360,
      "y": 80,
      "width": 180,
      "height": 80,
      "text": "Checkout API",
      "color": "ok",
      "fill": "tint"
    },
    {
      "id": "submit",
      "type": "arrow",
      "x1": 220,
      "y1": 120,
      "x2": 360,
      "y2": 120,
      "start": "client",
      "end": "api",
      "text": "POST /checkout",
      "head": "end"
    }
  ]
}
```

Shapes support `rectangle`, `ellipse`, `diamond`, `text`, and `table`, with
`x`, `y`, positive `width` and `height`. Arrows require `x1`, `y1`, `x2`, `y2`.
Their optional `start`/`end` refer to existing shape IDs. Table `rows` are
objects with unique `id`, `type`, and `name` strings; `startRow`/`endRow` can
attach an arrow to a row on its attached table.

Optional styles are `color` (`ink`, `accent`, `ok`, `warn`, `bad`, `violet`),
`fill` (`none`, `tint`), `stroke` (`solid`, `dashed`), `size` (`s`, `m`, `l`),
and arrow `head` (`end`, `both`, `none`). IDs must be unique ASCII letters,
digits, underscores or hyphens, up to 64 characters. Invalid layouts,
duplicates and missing attachment targets are rejected before saving.

The input schema conditionally requires bounding-box fields for non-arrow
elements and endpoint coordinates for arrows. Width and height must be
strictly positive when creating a shape. A non-null `startRow` or `endRow`
also requires the corresponding non-null table attachment. Attachment
errors identify the indexed element, field and missing target.

The editor fits table columns to their contents and calculates table height
from the selected size:

| Size | Header height | Row height |
| --- | ---: | ---: |
| `s` | 31 | 24 |
| `m` (default) | 36 | 28 |
| `l` | 44 | 34 |

Table height is header height plus row count times row height. For a
zero-based row index `i`, its center is `y + header + (i + 0.5) * row_height`.
An attached arrow endpoint faces the other element from the left or right
table edge. See the built-in diagram guide for a complete row-linked schema.

### HTTP samples

```json
{
  "description": "Create an order",
  "url": "https://api.example.test/orders",
  "method": "POST",
  "headers": [{"name": "Content-Type", "value": "application/json"}],
  "body": "{\"sku\":\"A123\",\"quantity\":1}",
  "tags": ["orders", "sample"]
}
```

`method` defaults to `GET`. Optional `body_type` is `none`, `text` (default),
`json`, or `form`; it controls the body and default Content-Type just as in
the editor. `body` is always a literal string: serialize JSON or URL-encode
form fields before passing it. `none` discards the body. An explicit
Content-Type header is preserved. JSON syntax is not validated, so deliberately
malformed body samples can be saved for testing.
Use `import_http_request` with a `curl` string to reuse a command;
it also accepts `description` and `tags`. Parsing never runs a shell or curl.

Samples appear in HTTP Client as **Saved sample**, with no response. Opening
one fills the request editor, ready for the user to send. They use the same
encrypted persistence and backup/restore as completed requests. List/get
results include `sent: false` for samples and `sent: true` for request history.
`get_http_request` returns the request; response payloads are not copied into
agent context.

## Protocol and implementation

The server implements MCP versions `2025-11-25`, `2025-06-18`, and
`2025-03-26` over [Streamable HTTP](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports).
Clients initialize, send `notifications/initialized`, and discover/call tools
using the [MCP tool protocol](https://modelcontextprotocol.io/specification/2025-11-25/server/tools).
An unsupported initialization version negotiates `2025-11-25`; subsequent
unsupported `MCP-Protocol-Version` headers receive HTTP 400. This implementation
does not advertise the newer `2026-07-28` per-request metadata protocol.

Every request needs the Bearer credential. POST uses `Content-Type:
application/json` and `Accept: application/json, text/event-stream`. Requests
return JSON; notifications return empty HTTP 202. GET and DELETE return 405
because this stateless server does not offer SSE or allocate protocol sessions.
Bodies are limited to 2 MB. Host, peer address, and any Origin header must be
local, even when the browser endpoint is configured for a public binding.

The transport runs before Phoenix's browser parser, with separate JSON-RPC
error handling and body limits. `MDTClient.MCP.Tools` calls the existing library
APIs, so encryption, identity isolation, search, and backup behavior remain
shared with the UI. Phoenix PubSub refreshes open pages after agent writes.
No additional runtime dependencies are required.

Run `mix precommit` to compile with warnings as errors, format, and execute the
suite. MCP tests cover credential lifetime, identity isolation, transport
errors, native diagram validation, unsent HTTP persistence and transfer, and
the connection screen and live refresh. Discovery tests create and read items
using examples fetched through `tools/list`, validate returned data against
the advertised output schemas, follow pagination and read bundled guides
through the authenticated endpoint.
