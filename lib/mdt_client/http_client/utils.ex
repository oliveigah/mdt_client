defmodule MDTClient.HttpClient.Utils do
  @moduledoc """
  Shared editor-state and presentation helpers for the HTTP client.
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

  @doc "Builds the editor state for one request tab."
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

  @doc "The URL with enabled query params appended, as it will be sent."
  def full_url(request) do
    query =
      request.params
      |> Enum.filter(&(&1.enabled and &1.key != ""))
      |> Enum.map(&{&1.key, &1.value})
      |> URI.encode_query()

    case {request.url, query} do
      {url, ""} -> url
      {url, query} -> url <> if(String.contains?(url, "?"), do: "&", else: "?") <> query
    end
  end

  @doc "The number of enabled rows, shown as a badge on the editor tabs."
  def enabled_count(rows), do: Enum.count(rows, &(&1.enabled and &1.key != ""))

  @doc "Groups history entries by the day they were sent, newest day first."
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

  @doc "Turns a query string into editable rows, always leaving a blank one at the end."
  def query_rows(""), do: [new_row()]

  def query_rows(query) do
    rows =
      query
      |> String.split("&", trim: true)
      |> Enum.map(fn pair ->
        case String.split(pair, "=", parts: 2) do
          [key] -> new_row(URI.decode_www_form(key), "")
          [key, value] -> new_row(URI.decode_www_form(key), URI.decode_www_form(value))
        end
      end)

    rows ++ [new_row()]
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
        503 => "Service Unavailable",
        599 => "Request Failed"
      },
      status,
      "Unknown"
    )
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

  defp new_id(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
