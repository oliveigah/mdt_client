defmodule MDTClient.HttpClient.Translation do
  @moduledoc """
  Translates between HTTP client editor state, Req structs, and stored history.
  """

  alias MDTClient.HttpClient.HistoryMetadata
  alias MDTClient.HttpClient.Utils

  @method_atoms %{
    "GET" => :get,
    "POST" => :post,
    "PUT" => :put,
    "PATCH" => :patch,
    "DELETE" => :delete,
    "HEAD" => :head,
    "OPTIONS" => :options
  }

  @doc "Converts editor state into a Req request."
  @spec to_req(map()) :: Req.Request.t()
  def to_req(request) do
    Req.new(
      method: Map.fetch!(@method_atoms, request.method),
      url: Utils.full_url(request),
      headers: request_headers(request),
      body: request_body(request)
    )
  end

  @doc "Builds a history-panel entry from a stored request tuple."
  @spec history_entry(
          {pos_integer(), HistoryMetadata.t(), Req.Request.t(), Req.Response.t() | Exception.t()}
        ) ::
          map()
  def history_entry(
        {identifier, %HistoryMetadata{} = metadata, %Req.Request{} = request, response}
      ) do
    tab = request_to_tab(request)
    response = response_view(response, metadata.duration_ms)

    %{
      id: to_string(identifier),
      name: metadata.description || Utils.label(tab),
      description: metadata.description,
      tags: metadata.tags,
      method: tab.method,
      url: Utils.full_url(tab),
      status: response.status,
      duration_ms: metadata.duration_ms,
      size: response.size,
      at: DateTime.to_naive(metadata.completed_at),
      request: request,
      response: response
    }
  end

  @doc "Builds an editor tab from a stored request tuple."
  @spec request_from_history(
          {pos_integer(), HistoryMetadata.t(), Req.Request.t(), Req.Response.t() | Exception.t()}
        ) ::
          map()
  def request_from_history(
        {identifier, %HistoryMetadata{} = metadata, %Req.Request{} = request, response}
      ) do
    request
    |> request_to_tab()
    |> Map.merge(%{
      source_id: to_string(identifier),
      name: metadata.description,
      tags: metadata.tags,
      response: response_view(response, metadata.duration_ms),
      response_tab: "body"
    })
  end

  @doc "Builds the response-panel state from a Req result or response."
  @spec response_view(
          Req.Response.t() | {:ok, Req.Response.t()} | {:error, Exception.t()} | Exception.t(),
          non_neg_integer()
        ) ::
          map()
  def response_view({:ok, response}, duration_ms), do: response_view(response, duration_ms)
  def response_view({:error, error}, duration_ms), do: response_view(error, duration_ms)

  def response_view(%Req.Response{} = response, duration_ms) do
    body = response_body_text(response.body)

    %{
      status: response.status,
      status_text: Utils.status_text(response.status),
      duration_ms: duration_ms,
      size: Utils.format_bytes(byte_size(body)),
      content_type: response.headers |> Map.get("content-type", []) |> List.first(),
      body: body,
      headers: response_headers(response.headers)
    }
  end

  def response_view(error, duration_ms) do
    body = Exception.message(error)

    %{
      status: 599,
      status_text: Utils.status_text(599),
      duration_ms: duration_ms,
      size: Utils.format_bytes(byte_size(body)),
      content_type: "text/plain",
      body: body,
      headers: []
    }
  end

  defp request_headers(request) do
    headers =
      request.headers
      |> Enum.filter(&(&1.enabled and &1.key != ""))
      |> Enum.map(&{&1.key, &1.value})
      |> Kernel.++(auth_headers(request))

    case request.body_type do
      "json" -> put_content_type(headers, "application/json")
      "form" -> put_content_type(headers, "application/x-www-form-urlencoded")
      "text" -> put_content_type(headers, "text/plain")
      _ -> headers
    end
  end

  defp auth_headers(%{auth_type: "bearer", auth_token: token}) when token != "" do
    [{"authorization", "Bearer " <> token}]
  end

  defp auth_headers(%{auth_type: "basic"} = request) do
    credentials = Base.encode64(request.auth_username <> ":" <> request.auth_password)
    [{"authorization", "Basic " <> credentials}]
  end

  defp auth_headers(_request), do: []

  defp put_content_type(headers, value) do
    if Enum.any?(headers, fn {name, _value} -> String.downcase(name) == "content-type" end) do
      headers
    else
      [{"content-type", value} | headers]
    end
  end

  defp request_body(%{body_type: "none"}), do: nil
  defp request_body(%{body: ""}), do: nil
  defp request_body(%{body: body}), do: body

  defp request_to_tab(%Req.Request{} = request) do
    uri = request.url
    url = uri |> Map.put(:query, nil) |> URI.to_string()

    Utils.new_request(%{
      method: request.method |> Atom.to_string() |> String.upcase(),
      url: url,
      params: Utils.query_rows(uri.query || ""),
      headers: header_rows(request.headers),
      body_type: request_body_type(request.body, request.headers),
      body: request_body_text(request.body),
      editor_tab: if(request.body in [nil, ""], do: "params", else: "body")
    })
  end

  defp header_rows(headers) do
    rows =
      for {name, values} <- headers, value <- List.wrap(values) do
        Utils.new_row(name, value)
      end

    rows ++ [Utils.new_row()]
  end

  defp request_body_type(body, _headers) when body in [nil, ""], do: "none"

  defp request_body_type(body, headers) do
    content_type = headers |> Map.get("content-type", []) |> Enum.join(" ") |> String.downcase()
    body = request_body_text(body)

    cond do
      String.contains?(content_type, "json") -> "json"
      String.contains?(content_type, "x-www-form-urlencoded") -> "form"
      String.starts_with?(String.trim_leading(body), "{") -> "json"
      String.starts_with?(String.trim_leading(body), "[") -> "json"
      String.contains?(body, "=") and not String.contains?(body, "\n") -> "form"
      true -> "text"
    end
  end

  defp response_headers(headers) do
    headers
    |> Enum.flat_map(fn {name, values} -> Enum.map(values, &{name, &1}) end)
    |> Enum.sort_by(fn {name, _value} -> name end)
  end

  defp request_body_text(body) when is_binary(body), do: body
  defp request_body_text(nil), do: ""
  defp request_body_text(body), do: inspect(body, pretty: true, limit: :infinity)

  defp response_body_text(body) when is_binary(body), do: body
  defp response_body_text(nil), do: ""

  defp response_body_text(body) do
    try do
      Jason.encode!(body, pretty: true)
    rescue
      Protocol.UndefinedError -> inspect(body, pretty: true, limit: :infinity)
    end
  end
end
