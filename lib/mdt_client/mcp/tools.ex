defmodule MDTClient.MCP.Tools do
  @moduledoc "Agent tools backed by MDT's existing encrypted libraries."

  alias MDTClient.Diagrams.Diagram
  alias MDTClient.Diagrams.Library, as: Diagrams
  alias MDTClient.Notes.Library, as: Notes
  alias MDTClient.Notes.Note
  alias MDTClient.HttpClient.{Curl, HistoryMetadata, Resources, Translation, Utils}
  alias MDTClient.MCP.{Catalogue, Schema}

  @doc "The fixed tool catalogue, including the schemas agents use to construct calls."
  def list, do: Catalogue.list()

  @doc "Validates arguments before calling a library."
  def call(name, arguments, username, base_url) do
    with tool when not is_nil(tool) <- Enum.find(list(), &(&1["name"] == name)),
         :ok <- Schema.validate(arguments, tool["inputSchema"]),
         {:ok, data} <- execute(name, arguments, username) do
      data = if data[:path], do: Map.put(data, :url, base_url <> data.path), else: data

      {:ok,
       %{
         "content" => [%{"type" => "text", "text" => Jason.encode!(data)}],
         "structuredContent" => data,
         "isError" => false
       }}
    else
      nil ->
        {:error, :unknown_tool}

      {:error, message} ->
        {:ok, %{"content" => [%{"type" => "text", "text" => message}], "isError" => true}}

      :error ->
        {:ok,
         %{
           "content" => [%{"type" => "text", "text" => "Item not found in this identity."}],
           "isError" => true
         }}
    end
  end

  defp execute("create_note", args, username) do
    with {:ok, note} <-
           Notes.save(username, Note.new_id(), %{title: args["title"], body: args["body"]}) do
      {:ok, note_data(note)}
    end
  end

  defp execute("get_note", args, username) do
    with {:ok, note} <- Notes.get(username, args["id"]), do: {:ok, note_data(note)}
  end

  defp execute("update_note", args, username) do
    attrs = update_attrs(args, [{"title", :title}, {"body", :body}])

    with {:ok, note} <- Notes.update(username, args["id"], attrs), do: {:ok, note_data(note)}
  end

  defp execute("list_notes", args, username) do
    items = Notes.list(username, Map.get(args, "query", ""))

    {:ok,
     page(items, args, fn note ->
       %{
         id: note.id,
         title: note.title,
         excerpt: note.excerpt,
         done: note.done_at != nil,
         updated_at: note.updated_at
       }
     end)}
  end

  defp execute("create_diagram", args, username) do
    with :ok <- validate_elements(args["elements"]),
         {:ok, diagram} <-
           Diagrams.save(username, Diagram.new_id(), %{
             title: args["title"],
             elements: args["elements"]
           }) do
      {:ok, diagram_data(diagram)}
    end
  end

  defp execute("get_diagram", args, username) do
    with {:ok, diagram} <- Diagrams.get(username, args["id"]), do: {:ok, diagram_data(diagram)}
  end

  defp execute("update_diagram", args, username) do
    attrs = update_attrs(args, [{"title", :title}, {"elements", :elements}])

    with :ok <- validate_updated_elements(args),
         {:ok, diagram} <- Diagrams.update(username, args["id"], attrs) do
      {:ok, diagram_data(diagram)}
    end
  end

  defp execute("list_diagrams", args, username) do
    {:ok,
     page(Diagrams.list(username, Map.get(args, "query", "")), args, fn diagram ->
       %{
         id: diagram.id,
         title: diagram.title,
         element_count: diagram.count,
         updated_at: diagram.updated_at
       }
     end)}
  end

  defp execute("create_http_request", args, username) do
    headers =
      for row <- Map.get(args, "headers", []), do: Utils.new_row(row["name"], row["value"])

    request =
      Utils.new_request(%{
        url: args["url"],
        method: Map.get(args, "method", "GET"),
        headers: headers,
        body: Map.get(args, "body", ""),
        body_type: Map.get(args, "body_type", "text")
      })

    save_request(username, request, args)
  end

  defp execute("import_http_request", args, username) do
    case Curl.from_curl(args["curl"]) do
      {:ok, attrs} -> save_request(username, Utils.new_request(attrs), args)
      {:error, reason} -> {:error, "Could not parse curl: #{reason}"}
    end
  end

  defp execute("list_http_requests", args, username) do
    {:ok,
     page(Resources.summaries(username, Map.get(args, "query", "")), args, fn
       {id, description, tags, at, _duration, method, url, status} ->
         %{
           id: id,
           description: description,
           tags: tags,
           saved_at: at,
           method: method |> to_string() |> String.upcase(),
           request_url: URI.to_string(url),
           sent: status != 0
         }
     end)}
  end

  defp execute("get_http_request", args, username) do
    with {:ok, entry} <- Resources.get(username, args["id"]), do: {:ok, request_data(entry)}
  end

  defp save_request(username, request, args) do
    url = URI.parse(Utils.full_url(request))

    if url.scheme in ["http", "https"] and is_binary(url.host) and url.host != "" and
         request.method in Utils.methods() do
      metadata =
        HistoryMetadata.new(%{description: args["description"], tags: Map.get(args, "tags", [])})

      request = Translation.to_req(request)
      id = Resources.record(username, metadata, request, nil)
      {:ok, request_data({id, metadata, request, nil})}
    else
      {:error, "Use an absolute http:// or https:// URL and a supported HTTP method."}
    end
  end

  defp update_attrs(args, fields) do
    for {key, field} <- fields, Map.has_key?(args, key), into: %{}, do: {field, args[key]}
  end

  defp validate_updated_elements(%{"elements" => elements}), do: validate_elements(elements)
  defp validate_updated_elements(_args), do: :ok

  defp note_data(note) do
    %{
      id: note.id,
      title: note.title,
      body: note.body,
      done: note.done_at != nil,
      created_at: note.created_at,
      updated_at: note.updated_at,
      path: "/tools/notes?id=#{note.id}"
    }
  end

  defp diagram_data(diagram) do
    %{
      id: diagram.id,
      title: diagram.title,
      elements: diagram.elements,
      created_at: diagram.created_at,
      updated_at: diagram.updated_at,
      path: "/tools/diagrams?id=#{diagram.id}"
    }
  end

  defp request_data({id, metadata, request, response}) do
    %{
      id: id,
      description: metadata.description,
      tags: metadata.tags,
      method: request.method |> to_string() |> String.upcase(),
      request_url: URI.to_string(request.url),
      headers: request.headers,
      body: request.body || "",
      sent: response != nil,
      saved_at: metadata.completed_at,
      path: "/tools/http?id=#{id}"
    }
  end

  defp page(items, args, fun) do
    offset = Map.get(args, "offset", 0)
    limit = Map.get(args, "limit", 20)
    total = length(items)

    %{
      items: items |> Enum.slice(offset, limit) |> Enum.map(fun),
      total: total,
      next_offset: if(offset + limit < total, do: offset + limit, else: nil)
    }
  end

  # The canvas sanitizer is forgiving for interactive editing. Agent input is
  # checked before saving so duplicates and broken arrows cannot silently vanish.
  defp validate_elements(elements) do
    ids = Enum.map(elements, & &1["id"])
    targets = Map.new(elements, &{&1["id"], &1})

    error =
      elements
      |> Enum.with_index()
      |> Enum.find_value(fn {element, index} ->
        path = "arguments.elements[#{index}]"
        fields = if element["type"] == "arrow", do: ~w(x1 y1 x2 y2), else: ~w(x y width height)

        cond do
          not Diagram.id?(element["id"]) ->
            "#{path}.id must use 1–64 ASCII letters, digits, underscores or hyphens."

          Enum.any?(fields, &(not Map.has_key?(element, &1))) ->
            "#{path} (#{element["id"]}) requires #{Enum.join(fields, ", ")}."

          element["type"] != "arrow" and (element["width"] <= 0 or element["height"] <= 0) ->
            "#{path} (#{element["id"]}) requires positive width and height."

          element["type"] == "table" and invalid_rows?(Map.get(element, "rows", [])) ->
            "#{path}.rows requires valid row IDs unique within table #{inspect(element["id"])}."

          element["type"] == "arrow" ->
            validate_attachments(element, targets, path)

          true ->
            nil
        end
      end)

    cond do
      length(ids) != length(Enum.uniq(ids)) ->
        counts = Enum.frequencies(ids)
        duplicate = Enum.find(ids, &(counts[&1] > 1))

        {:error,
         "arguments.elements contains duplicate ID #{inspect(duplicate)}; use a unique ID for every element."}

      error ->
        {:error, error}

      true ->
        :ok
    end
  end

  defp invalid_rows?(rows) do
    Enum.any?(rows, &(not Diagram.id?(&1["id"]))) or
      length(rows) != length(Enum.uniq_by(rows, & &1["id"]))
  end

  defp validate_attachments(arrow, targets, path) do
    Enum.find_value([{"start", "startRow"}, {"end", "endRow"}], fn {endpoint, row_key} ->
      id = arrow[endpoint]
      row = arrow[row_key]
      target = targets[id]

      cond do
        id != nil and (target == nil or target["type"] == "arrow") ->
          "#{path}.#{endpoint} names #{inspect(id)}, which must be an existing non-arrow element ID in this diagram."

        row != nil and
            (target == nil or not Enum.any?(Map.get(target, "rows", []), &(&1["id"] == row))) ->
          "#{path}.#{row_key} names #{inspect(row)}, which must be a row ID on the table referenced by #{endpoint}=#{inspect(id)}."

        true ->
          nil
      end
    end)
  end
end
