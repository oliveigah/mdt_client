defmodule MDTClient.HttpClient do
  @moduledoc """
  Requests, responses and history for the HTTP client tool.

  Nothing here touches the network yet: `perform/1` returns canned responses so
  the interface can be exercised end to end. Requests, rows and history entries
  are plain maps to keep the shape easy to swap for real structs later.
  """

  @methods ~w(GET POST PUT PATCH DELETE HEAD OPTIONS)
  @body_types [{"None", "none"}, {"JSON", "json"}, {"Text", "text"}, {"Form", "form"}]
  @auth_types [{"No auth", "none"}, {"Bearer token", "bearer"}, {"Basic", "basic"}]

  @doc "The HTTP methods offered by the method picker."
  def methods, do: @methods

  @doc "The `{label, value}` pairs for the body type picker."
  def body_types, do: @body_types

  @doc "The `{label, value}` pairs for the auth type picker."
  def auth_types, do: @auth_types

  @doc """
  Builds a request, merging the given attributes over the defaults.

  The map carries both the request itself and the little bit of per-tab UI
  state (which editor/response tab is open, whether it is in flight).
  """
  def new_request(attrs \\ %{}) do
    Map.merge(
      %{
        id: new_id("tab"),
        source_id: nil,
        name: nil,
        method: "GET",
        url: "",
        params: [new_row()],
        headers: [new_row("Accept", "application/json"), new_row()],
        body_type: "none",
        body: "",
        auth_type: "none",
        auth_token: "",
        auth_username: "",
        auth_password: "",
        editor_tab: "params",
        response_tab: "body",
        state: :idle,
        pending: nil,
        response: nil
      },
      attrs
    )
  end

  @doc "Builds an empty key/value row for the params and headers editors."
  def new_row(key \\ "", value \\ "") do
    %{id: new_id("row"), key: key, value: value, enabled: true}
  end

  defp new_id(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  @doc "The label shown on a request tab."
  def label(%{name: name}) when is_binary(name) and name != "", do: name
  def label(%{url: url}) when url in ["", nil], do: "New Request"

  def label(%{url: url}) do
    uri = URI.parse(url)

    case uri.path do
      path when path in [nil, "", "/"] -> uri.host || url
      path -> "/" <> (path |> String.trim("/") |> String.split("/") |> List.last())
    end
  end

  @doc "The URL with the enabled query params appended, as it would be sent."
  def full_url(request) do
    query =
      request.params
      |> Enum.filter(&(&1.enabled and &1.key != ""))
      |> Enum.map_join("&", &"#{&1.key}=#{&1.value}")

    case {request.url, query} do
      {url, ""} -> url
      {url, query} -> url <> if(String.contains?(url, "?"), do: "&", else: "?") <> query
    end
  end

  @doc "The number of enabled rows, shown as a badge on the editor tabs."
  def enabled_count(rows), do: Enum.count(rows, &(&1.enabled and &1.key != ""))

  @doc "A mocked response for the given request."
  def perform(request) do
    url = full_url(request)
    {status, body, content_type} = canned_response(request, url)

    %{
      status: status,
      status_text: status_text(status),
      duration_ms: 40 + :rand.uniform(260),
      size: format_bytes(byte_size(body)),
      content_type: content_type,
      body: body,
      headers: response_headers(body, content_type),
      at: NaiveDateTime.local_now()
    }
  end

  @doc "A history entry for a request that has just been answered."
  def history_entry(request, response) do
    %{
      id: new_id("hist"),
      name: label(request),
      method: request.method,
      url: full_url(request),
      status: response.status,
      duration_ms: response.duration_ms,
      size: response.size,
      at: response.at,
      attrs:
        Map.take(request, [
          :name,
          :method,
          :url,
          :params,
          :headers,
          :body_type,
          :body,
          :auth_type,
          :auth_token,
          :auth_username,
          :auth_password
        ]),
      response: response
    }
  end

  @doc "Builds a request tab from a history entry, response included."
  def request_from_history(entry) do
    entry.attrs
    |> Map.put(:source_id, entry.id)
    |> Map.put(:response, entry.response)
    |> Map.put(:response_tab, "body")
    |> new_request()
  end

  @doc "Filters history entries by a free text term."
  def search_history(history, term) do
    case String.trim(term) do
      "" ->
        history

      term ->
        term = String.downcase(term)

        Enum.filter(history, fn entry ->
          [entry.name, entry.method, entry.url, to_string(entry.status)]
          |> Enum.any?(&String.contains?(String.downcase(&1), term))
        end)
    end
  end

  @doc """
  Groups history entries by the day they were sent, newest day first.

  Each group is a `{label, key, entries}` tuple: the label is what the sidebar
  shows ("Today", "Yesterday", a weekday for the past week, a date before that)
  and the key is the ISO date, used to track which groups are collapsed.
  """
  def group_history(history) do
    today = NaiveDateTime.to_date(NaiveDateTime.local_now())

    history
    |> Enum.group_by(&NaiveDateTime.to_date(&1.at))
    |> Enum.sort_by(fn {date, _entries} -> date end, {:desc, Date})
    |> Enum.map(fn {date, entries} ->
      {day_label(date, today), Date.to_iso8601(date),
       Enum.sort_by(entries, & &1.at, {:desc, NaiveDateTime})}
    end)
  end

  defp day_label(date, today) do
    case Date.diff(today, date) do
      0 -> "Today"
      1 -> "Yesterday"
      days when days in 2..6 -> Calendar.strftime(date, "%A")
      _ when date.year == today.year -> Calendar.strftime(date, "%b %-d")
      _ -> Calendar.strftime(date, "%b %-d, %Y")
    end
  end

  @doc "The two requests open when the tool boots."
  def sample_tabs do
    users =
      new_request(%{
        name: "List users",
        method: "GET",
        url: "https://api.mdt.dev/v1/users",
        params: [new_row("page", "1"), new_row("per_page", "2"), new_row()],
        headers: [new_row("Accept", "application/json"), new_row()],
        auth_type: "bearer",
        auth_token: "mdt_live_2f8c19d4b7a3",
        editor_tab: "params"
      })

    create_order =
      new_request(%{
        name: "Create order",
        method: "POST",
        url: "https://api.mdt.dev/v1/orders",
        headers: [
          new_row("Content-Type", "application/json"),
          new_row("Idempotency-Key", "ord_9f31"),
          new_row()
        ],
        body_type: "json",
        body: order_payload(),
        editor_tab: "body"
      })

    [%{users | response: perform(users)}, create_order]
  end

  @doc "A mocked history of previously sent requests, newest first."
  def history do
    now = NaiveDateTime.local_now()

    [
      {"List users", "GET", "https://api.mdt.dev/v1/users?page=1&per_page=2", 200, 128, 12},
      {"Get user", "GET", "https://api.mdt.dev/v1/users/42", 200, 86, 47},
      {"Create order", "POST", "https://api.mdt.dev/v1/orders", 201, 213, 64},
      {"Sign in", "POST", "https://api.mdt.dev/v1/auth/login", 401, 154, 96},
      {"Sign in", "POST", "https://api.mdt.dev/v1/auth/login", 200, 171, 98},
      {"Health", "GET", "https://api.mdt.dev/health", 200, 41, 121},
      {"Update user", "PATCH", "https://api.mdt.dev/v1/users/42", 200, 192, 1_520},
      {"Delete order", "DELETE", "https://api.mdt.dev/v1/orders/ord_9f31", 204, 97, 1_610},
      {"Search orders", "GET", "https://api.mdt.dev/v1/orders?status=paid", 200, 233, 1_705},
      {"Webhook replay", "POST", "https://api.mdt.dev/v1/webhooks/replay", 500, 812, 2_930},
      {"Missing page", "GET", "https://api.mdt.dev/v1/pages/missing", 404, 73, 3_050},
      {"List users", "GET", "https://api.mdt.dev/v1/users", 200, 119, 4_400},
      {"Search orders", "GET", "https://api.mdt.dev/v1/orders?status=pending", 200, 141, 5_900},
      {"Rotate token", "POST", "https://api.mdt.dev/v1/auth/rotate", 200, 205, 8_700},
      {"Import users", "POST", "https://api.mdt.dev/v1/users/import", 202, 1_284, 12_500},
      {"Delete webhook", "DELETE", "https://api.mdt.dev/v1/webhooks/wh_21", 204, 64, 16_100},
      {"Legacy export", "GET", "https://api.mdt.dev/v1/exports/2025", 200, 442, 61_000}
    ]
    |> Enum.map(fn {name, method, url, status, duration, minutes_ago} ->
      at = NaiveDateTime.add(now, -minutes_ago * 60, :second)
      {base_url, query} = split_url(url)
      body = canned_body(status, url)

      %{
        id: new_id("hist"),
        name: name,
        method: method,
        url: url,
        status: status,
        duration_ms: duration,
        size: format_bytes(byte_size(body)),
        at: at,
        attrs: %{
          name: name,
          method: method,
          url: base_url,
          params: query_rows(query),
          headers: [new_row("Accept", "application/json"), new_row()],
          body_type: if(method in ~w(POST PUT PATCH), do: "json", else: "none"),
          body: if(method in ~w(POST PUT PATCH), do: order_payload(), else: "")
        },
        response: %{
          status: status,
          status_text: status_text(status),
          duration_ms: duration,
          size: format_bytes(byte_size(body)),
          content_type: "application/json",
          body: body,
          headers: response_headers(body, "application/json"),
          at: at
        }
      }
    end)
  end

  defp split_url(url) do
    case String.split(url, "?", parts: 2) do
      [base] -> {base, ""}
      [base, query] -> {base, query}
    end
  end

  @doc "Turns a query string into editable rows, always leaving a blank one at the end."
  def query_rows(""), do: [new_row()]

  def query_rows(query) do
    rows =
      query
      |> String.split("&", trim: true)
      |> Enum.map(fn pair ->
        case String.split(pair, "=", parts: 2) do
          [key] -> new_row(key, "")
          [key, value] -> new_row(key, value)
        end
      end)

    rows ++ [new_row()]
  end

  defp canned_response(request, url) do
    status =
      cond do
        String.contains?(url, "missing") -> 404
        String.contains?(url, "replay") -> 500
        String.contains?(url, "login") and not String.contains?(request.body, "password") -> 401
        String.contains?(url, "login") -> 200
        request.method == "POST" -> 201
        request.method == "DELETE" -> 204
        true -> 200
      end

    {status, canned_body(status, url), "application/json"}
  end

  defp canned_body(204, _url), do: ""

  defp canned_body(404, _url) do
    """
    {
      "error": "not_found",
      "message": "The requested resource does not exist",
      "request_id": "req_7c1a93f0"
    }\
    """
  end

  defp canned_body(500, _url) do
    """
    {
      "error": "internal_server_error",
      "message": "Unexpected failure while replaying the webhook",
      "request_id": "req_11de44a2",
      "retryable": true
    }\
    """
  end

  defp canned_body(401, _url) do
    """
    {
      "error": "invalid_credentials",
      "message": "Email or password is incorrect",
      "attempts_left": 4
    }\
    """
  end

  defp canned_body(status, url) do
    cond do
      String.contains?(url, "login") ->
        """
        {
          "token": "mdt_live_2f8c19d4b7a3",
          "token_type": "bearer",
          "expires_in": 3600,
          "user": {
            "id": 42,
            "email": "dev@mdt.local",
            "name": "Dev"
          }
        }\
        """

      String.contains?(url, "health") ->
        """
        {
          "status": "ok",
          "version": "0.1.0",
          "uptime_seconds": 918234,
          "checks": {
            "database": "ok",
            "cache": "ok"
          }
        }\
        """

      Regex.match?(~r{/users/\d+}, url) ->
        """
        {
          "id": 42,
          "email": "ada@mdt.dev",
          "name": "Ada Lovelace",
          "role": "admin",
          "active": true,
          "last_seen_at": "2026-09-19T11:04:22Z",
          "teams": ["platform", "tooling"]
        }\
        """

      String.contains?(url, "users") ->
        """
        {
          "data": [
            {
              "id": 42,
              "email": "ada@mdt.dev",
              "name": "Ada Lovelace",
              "role": "admin",
              "active": true
            },
            {
              "id": 43,
              "email": "grace@mdt.dev",
              "name": "Grace Hopper",
              "role": "member",
              "active": true
            }
          ],
          "meta": {
            "page": 1,
            "per_page": 2,
            "total": 137
          }
        }\
        """

      String.contains?(url, "orders") and status == 201 ->
        """
        {
          "id": "ord_9f31",
          "status": "pending",
          "amount_cents": 12900,
          "currency": "BRL",
          "items": [
            {
              "sku": "MDT-PRO",
              "quantity": 1,
              "unit_price_cents": 12900
            }
          ],
          "created_at": "2026-09-19T11:31:08Z"
        }\
        """

      String.contains?(url, "orders") ->
        """
        {
          "data": [
            {
              "id": "ord_9f31",
              "status": "paid",
              "amount_cents": 12900,
              "currency": "BRL"
            },
            {
              "id": "ord_9f2e",
              "status": "paid",
              "amount_cents": 4900,
              "currency": "BRL"
            }
          ],
          "meta": {
            "total": 2
          }
        }\
        """

      true ->
        path = URI.parse(url).path || "/"

        """
        {
          "ok": true,
          "path": "#{path}",
          "echo": {
            "received_at": "2026-09-19T11:42:57Z",
            "mocked": true
          }
        }\
        """
    end
  end

  defp order_payload do
    """
    {
      "customer_id": 42,
      "currency": "BRL",
      "items": [
        {
          "sku": "MDT-PRO",
          "quantity": 1
        }
      ]
    }\
    """
  end

  defp response_headers("", _content_type) do
    [
      {"date", "Fri, 19 Sep 2026 11:42:57 GMT"},
      {"server", "mdt-mock/0.1"},
      {"x-request-id", "req_7c1a93f0"}
    ]
  end

  defp response_headers(body, content_type) do
    [
      {"content-type", content_type <> "; charset=utf-8"},
      {"content-length", to_string(byte_size(body))},
      {"date", "Fri, 19 Sep 2026 11:42:57 GMT"},
      {"server", "mdt-mock/0.1"},
      {"cache-control", "no-store"},
      {"x-request-id", "req_7c1a93f0"},
      {"x-ratelimit-remaining", "4998"}
    ]
  end

  @doc "Formats a byte count for the response summary."
  def format_bytes(bytes) when bytes < 1024, do: "#{bytes} B"
  def format_bytes(bytes) when bytes < 1024 * 1024, do: "#{Float.round(bytes / 1024, 1)} KB"
  def format_bytes(bytes), do: "#{Float.round(bytes / (1024 * 1024), 1)} MB"

  @doc "The reason phrase for a status code."
  def status_text(status) do
    Map.get(
      %{
        200 => "OK",
        201 => "Created",
        202 => "Accepted",
        204 => "No Content",
        301 => "Moved Permanently",
        304 => "Not Modified",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        409 => "Conflict",
        422 => "Unprocessable Entity",
        429 => "Too Many Requests",
        500 => "Internal Server Error",
        502 => "Bad Gateway",
        503 => "Service Unavailable"
      },
      status,
      "Unknown"
    )
  end
end
