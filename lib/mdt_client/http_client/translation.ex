defmodule MDTClient.HttpClient.Translation do
  @moduledoc """
  Translates between HTTP client editor state, Req structs, and stored history.
  """

  alias MDTClient.HttpClient.HistoryMetadata
  alias MDTClient.HttpClient.Resources
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
    {:ok, timeout_ms} = Utils.parse_timeout_ms(request.timeout_ms)

    Req.new(
      method: Map.fetch!(@method_atoms, request.method),
      url: Utils.full_url(request),
      headers: request_headers(request),
      body: request_body(request),
      request_timeout: timeout_ms,
      receive_timeout: timeout_ms,
      decode_body: false,
      retry: false
    )
  end

  @doc "Builds a history-panel entry from a stored request tuple."
  @spec history_entry(Resources.entry() | Resources.summary()) :: map()
  def history_entry(
        {identifier, %HistoryMetadata{} = metadata, %Req.Request{} = request, response}
      ) do
    history_entry({
      identifier,
      metadata.description,
      metadata.tags,
      metadata.completed_at,
      metadata.duration_ms,
      request.method,
      request.url,
      response_status(response)
    })
  end

  def history_entry(
        {identifier, description, tags, completed_at, duration_ms, method, url, status}
      ) do
    method = method |> Atom.to_string() |> String.upcase()
    url = URI.to_string(url)

    %{
      id: to_string(identifier),
      name: description || Utils.label(%{url: url}),
      description: description,
      tags: tags,
      method: method,
      url: url,
      status: status,
      duration_ms: duration_ms,
      at: DateTime.to_naive(completed_at)
    }
  end

  @doc "Builds an editor tab from a stored request tuple."
  @spec request_from_history(Resources.entry()) :: map()
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

  @doc "Builds an editor tab without formatting or retaining its response body."
  @spec request_outline_from_history(Resources.entry() | Resources.outline()) :: map()
  def request_outline_from_history(
        {identifier, %HistoryMetadata{} = metadata, %Req.Request{} = request,
         {:response, status, headers, size_bytes}}
      ) do
    request
    |> request_to_tab()
    |> Map.merge(%{
      source_id: to_string(identifier),
      name: metadata.description,
      tags: metadata.tags,
      response: response_summary(status, headers, size_bytes, metadata.duration_ms),
      response_tab: "body"
    })
  end

  def request_outline_from_history(
        {identifier, %HistoryMetadata{} = metadata, %Req.Request{} = request, {:error, error}}
      ) do
    request_outline_from_history({identifier, metadata, request, error})
  end

  def request_outline_from_history({identifier, metadata, request, :sample}) do
    request_outline_from_history({identifier, metadata, request, nil})
  end

  def request_outline_from_history(
        {identifier, %HistoryMetadata{} = metadata, %Req.Request{} = request, response}
      ) do
    request
    |> request_to_tab()
    |> Map.merge(%{
      source_id: to_string(identifier),
      name: metadata.description,
      tags: metadata.tags,
      response: response_summary(response, metadata.duration_ms),
      response_tab: "body"
    })
  end

  @doc "Builds response metadata without formatting or copying the body into UI state."
  @spec response_summary(
          Resources.response() | {:ok, Req.Response.t()} | {:error, Exception.t()},
          non_neg_integer()
        ) :: map() | nil
  def response_summary({:ok, response}, duration_ms), do: response_summary(response, duration_ms)
  def response_summary({:error, error}, duration_ms), do: response_summary(error, duration_ms)
  def response_summary(nil, _duration_ms), do: nil

  def response_summary(%Req.Response{} = response, duration_ms) do
    size_bytes = Utils.response_body_size(response)

    response_summary(response.status, response.headers, size_bytes, duration_ms)
  end

  def response_summary(error, duration_ms) do
    error
    |> response_view(duration_ms)
    |> Map.put(:body_loading?, false)
  end

  defp response_summary(status, headers, size_bytes, duration_ms) do
    %{
      status: status,
      status_text: Utils.status_text(status),
      duration_ms: duration_ms,
      size: Utils.format_bytes(size_bytes),
      size_bytes: size_bytes,
      content_type: headers |> Map.get("content-type", []) |> List.first(),
      body: nil,
      body_loaded?: false,
      body_loading?: false,
      headers: response_headers(headers)
    }
  end

  @doc "Builds the response-panel state from a Req result or response."
  @spec response_view(
          Resources.response() | {:ok, Req.Response.t()} | {:error, Exception.t()},
          non_neg_integer()
        ) ::
          map() | nil
  def response_view({:ok, response}, duration_ms), do: response_view(response, duration_ms)
  def response_view({:error, error}, duration_ms), do: response_view(error, duration_ms)
  def response_view(nil, _duration_ms), do: nil

  def response_view(%Req.Response{} = response, duration_ms) do
    body = response_body_text(response.body)
    size_bytes = byte_size(body)

    %{
      status: response.status,
      status_text: Utils.status_text(response.status),
      duration_ms: duration_ms,
      size: Utils.format_bytes(size_bytes),
      size_bytes: size_bytes,
      content_type: response.headers |> Map.get("content-type", []) |> List.first(),
      body: body,
      body_loaded?: true,
      body_loading?: false,
      headers: response_headers(response.headers)
    }
  end

  def response_view(error, duration_ms) do
    body = Exception.message(error)
    size_bytes = byte_size(body)

    %{
      status: 599,
      status_text: Utils.status_text(599),
      duration_ms: duration_ms,
      size: Utils.format_bytes(size_bytes),
      content_type: "text/plain",
      body: body,
      size_bytes: size_bytes,
      body_loaded?: true,
      body_loading?: false,
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
      timeout_ms: request_timeout_ms(request),
      editor_tab: if(request.body in [nil, ""], do: "params", else: "body")
    })
  end

  defp request_timeout_ms(request) do
    request.options
    |> Map.get(:request_timeout, :infinity)
    |> Utils.timeout_value()
  end

  defp response_status(nil), do: 0
  defp response_status(%Req.Response{status: status}), do: status
  defp response_status(_error), do: 599

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
