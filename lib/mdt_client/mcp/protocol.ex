defmodule MDTClient.MCP.Protocol do
  @moduledoc "The JSON-RPC methods for MDT's stateless MCP server."

  alias MDTClient.MCP.{Guides, Tools}

  @versions ~w(2025-11-25 2025-06-18 2025-03-26)

  def versions, do: @versions

  def handle(message, username, base_url) do
    case message do
      %{"jsonrpc" => "2.0", "id" => id, "method" => method}
      when (is_binary(id) or is_integer(id)) and is_binary(method) ->
        params = Map.get(message, "params", %{})

        if is_map(params),
          do: dispatch(id, method, params, username, base_url),
          else: error(id, -32602, "Params must be an object.")

      %{"jsonrpc" => "2.0", "method" => method}
      when is_binary(method) and not is_map_key(message, "id") ->
        if is_map(Map.get(message, "params", %{})),
          do: :accepted,
          else: error(nil, -32600, "Invalid notification.")

      _invalid ->
        error(nil, -32600, "Invalid JSON-RPC request. Send one request per POST.")
    end
  end

  def error(id, code, message),
    do: %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}}

  defp dispatch(id, "initialize", params, _username, _base_url) do
    case params do
      %{
        "protocolVersion" => version,
        "capabilities" => capabilities,
        "clientInfo" => %{"name" => name, "version" => client_version}
      }
      when is_binary(version) and is_map(capabilities) and is_binary(name) and
             is_binary(client_version) ->
        result(id, %{
          "protocolVersion" => if(version in @versions, do: version, else: hd(@versions)),
          "capabilities" => %{
            "tools" => %{"listChanged" => false},
            "resources" => %{"subscribe" => false, "listChanged" => false}
          },
          "serverInfo" => %{
            "name" => "mdt",
            "version" => Application.spec(:mdt_client, :vsn) |> to_string()
          },
          "instructions" => """
          MDT is a local encrypted developer toolbox. Tools operate only on the identity that issued your token.
          Create native diagrams, Markdown notes, or HTTP request samples; samples are saved without sending requests.
          Use list/get tools to find and inspect existing work. update_note and update_diagram edit existing items
          by ID; supply only the fields you want to change. Body/elements replace their complete saved content.
          Each create/import call creates a new item; repeating a successful call creates a duplicate.
          HTTP requests are append-only through MCP: save a new sample instead of updating an existing request.
          Deletion, completing notes and HTTP execution are not available through MCP.
          Returned url opens the saved item in MDT; request_url is an API destination.

          Tool schemas include field descriptions, defaults, examples and response contracts. No repository access
          is needed. Built-in guides are available through resources/list and resources/read:
          mdt://guides/notes, mdt://guides/diagrams and mdt://guides/http. Read the diagram guide for table sizing
          and row anchors. All list tools use query, limit (default 20) and offset (default 0); keep query and limit
          fixed and follow next_offset until null. Note/diagram search matches every word; HTTP search matches a substring.

          Tokens persist across restarts. Access requires the vault to be unlocked; use the same token again after unlocking.
          """
        })

      _invalid ->
        error(id, -32602, "initialize requires protocolVersion, capabilities and clientInfo.")
    end
  end

  defp dispatch(id, "ping", _params, _username, _base_url), do: result(id, %{})

  defp dispatch(id, "tools/list", params, _username, _base_url) do
    if Map.get(params, "cursor") in [nil, ""],
      do: result(id, %{"tools" => Tools.list()}),
      else: error(id, -32602, "Invalid tools cursor.")
  end

  defp dispatch(id, "resources/list", params, _username, _base_url) do
    if Map.get(params, "cursor") in [nil, ""],
      do: result(id, %{"resources" => Guides.list()}),
      else: error(id, -32602, "Invalid resources cursor.")
  end

  defp dispatch(id, "resources/templates/list", params, _username, _base_url) do
    if Map.get(params, "cursor") in [nil, ""],
      do: result(id, %{"resourceTemplates" => []}),
      else: error(id, -32602, "Invalid resource templates cursor.")
  end

  defp dispatch(id, "resources/read", %{"uri" => uri}, _username, _base_url)
       when is_binary(uri) do
    case Guides.read(uri) do
      {:ok, content} ->
        result(id, %{"contents" => [content]})

      :error ->
        error(id, -32002, "Unknown MDT guide. Use resources/list to find available guide URIs.")
    end
  end

  defp dispatch(id, "resources/read", _params, _username, _base_url),
    do: error(id, -32602, "resources/read requires a string uri from resources/list.")

  defp dispatch(id, "tools/call", %{"name" => name} = params, username, base_url)
       when is_binary(name) do
    case Tools.call(name, Map.get(params, "arguments", %{}), username, base_url) do
      {:ok, output} -> result(id, output)
      {:error, :unknown_tool} -> error(id, -32602, "Unknown MDT tool.")
    end
  rescue
    ArgumentError -> error(id, -32603, "The tool could not process this input.")
    RuntimeError -> error(id, -32000, "The vault is unavailable. Unlock MDT and reconnect.")
  catch
    :exit, _reason -> error(id, -32000, "The vault is unavailable. Unlock MDT and reconnect.")
  end

  defp dispatch(id, "tools/call", _params, _username, _base_url),
    do: error(id, -32602, "tools/call requires a tool name.")

  defp dispatch(id, _method, _params, _username, _base_url),
    do: error(id, -32601, "Method not found.")

  defp result(id, result), do: %{"jsonrpc" => "2.0", "id" => id, "result" => result}
end
