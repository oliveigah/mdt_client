defmodule MDTClientWeb.Plugs.MCP do
  @moduledoc """
  Local authenticated Streamable HTTP with JSON responses and no SSE stream.

  Runs before the browser's body parser, so JSON-RPC parse errors and body
  limits belong to this transport and request samples never enter param logs.
  """
  import Plug.Conn

  alias MDTClient.MCP.{Access, Protocol}

  @loopback ~w(127.0.0.1 localhost ::1)
  @max_body 2_000_000

  def init(opts), do: opts

  def call(%{path_info: ["mcp"]} = conn, _opts) do
    conn = put_resp_header(conn, "cache-control", "no-store")

    cond do
      conn.host not in @loopback or not local_peer?(conn.remote_ip) or not valid_origin?(conn) ->
        fail(conn, 403, -32000, "MCP accepts local connections and local origins only.")

      true ->
        case Access.authorize(bearer(conn)) do
          {:ok, username} ->
            serve(conn, username)

          :error ->
            conn
            |> put_resp_header("www-authenticate", "Bearer realm=\"MDT\"")
            |> fail(
              401,
              -32000,
              "Unlock the identity in MDT and supply its Bearer token. Enable agent access if it has not been configured."
            )
        end
    end
  end

  def call(conn, _opts), do: conn

  defp serve(%{method: "POST"} = conn, username) do
    version = get_req_header(conn, "mcp-protocol-version")

    cond do
      version != [] and version not in Enum.map(Protocol.versions(), &[&1]) ->
        fail(
          conn,
          400,
          -32600,
          "Unsupported MCP protocol version. Supported: #{Enum.join(Protocol.versions(), ", ")}"
        )

      not content_type?(conn) ->
        fail(conn, 415, -32600, "Content-Type must be application/json.")

      not accepts_json?(conn) ->
        fail(conn, 406, -32600, "Accept must include application/json and text/event-stream.")

      true ->
        read_message(conn, username)
    end
  end

  defp serve(conn, _username) do
    conn |> put_resp_header("allow", "POST") |> send_resp(405, "") |> halt()
  end

  defp read_message(conn, username) do
    case read_body(conn, length: @max_body, read_length: @max_body, read_timeout: 5_000) do
      {:ok, body, conn} when byte_size(body) <= @max_body ->
        case Jason.decode(body) do
          {:ok, message} ->
            base_url =
              URI.to_string(%URI{
                scheme: to_string(conn.scheme),
                host: conn.host,
                port: conn.port
              })

            case Protocol.handle(message, username, base_url) do
              :accepted -> conn |> send_resp(202, "") |> halt()
              response -> json(conn, 200, response)
            end

          {:error, _reason} ->
            fail(conn, 400, -32700, "Invalid JSON.")
        end

      {_status, _body, conn} ->
        fail(conn, 413, -32600, "MCP request body exceeds #{@max_body} bytes.")

      {:error, _reason} ->
        fail(conn, 400, -32600, "Could not read the MCP request body.")
    end
  end

  defp fail(conn, status, code, message),
    do: json(conn, status, Protocol.error(nil, code, message))

  defp json(conn, status, body),
    do:
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(body))
      |> halt()

  defp bearer(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] when byte_size(token) == 43 -> token
      _invalid -> nil
    end
  end

  defp content_type?(conn) do
    case get_req_header(conn, "content-type") do
      [value] ->
        value |> String.split(";") |> hd() |> String.trim() |> String.downcase() ==
          "application/json"

      _invalid ->
        false
    end
  end

  defp accepts_json?(conn) do
    types =
      conn
      |> get_req_header("accept")
      |> Enum.join(",")
      |> String.split(",")
      |> Enum.map(&(String.split(&1, ";") |> hd() |> String.trim()))

    "application/json" in types and "text/event-stream" in types
  end

  defp valid_origin?(conn) do
    case get_req_header(conn, "origin") do
      [] ->
        true

      [origin] ->
        uri = URI.parse(origin)

        uri.scheme == to_string(conn.scheme) and uri.host in @loopback and uri.port == conn.port and
          uri.userinfo == nil and uri.path in [nil, ""] and uri.query == nil and
          uri.fragment == nil

      _invalid ->
        false
    end
  end

  defp local_peer?({127, _, _, _}), do: true
  defp local_peer?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp local_peer?(_address), do: false
end
