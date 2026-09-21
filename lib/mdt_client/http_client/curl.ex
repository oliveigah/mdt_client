defmodule MDTClient.HttpClient.Curl do
  @moduledoc """
  Converts requests to and from `curl` commands.

  `to_curl/1` renders the command the request would run; `from_curl/1` parses a
  pasted command back into request attributes. The parser understands the flags
  people actually paste out of browser devtools or a README (`-X`, `-H`, `-d`,
  `-u`, `--url` and their long forms), tolerates line continuations and quoting,
  and skips flags that do not describe the request, like `-L` or `--compressed`.
  """

  alias MDTClient.HttpClient.Utils

  @body_flags ~w(-d --data --data-raw --data-binary --data-ascii --json)
  @header_flags ~w(-H --header)
  @method_flags ~w(-X --request)
  @user_flags ~w(-u --user)
  @url_flags ~w(--url)

  @doc """
  Renders the request as a multi line curl command.

  ## Examples

      iex> MDTClient.HttpClient.Curl.to_curl(MDTClient.HttpClient.Utils.new_request(%{url: "https://mdt.dev"}))
      "curl --request GET \\\\\\n  --url 'https://mdt.dev'"

  """
  def to_curl(request) do
    parts =
      ["--request #{request.method}", "--url #{quoted(Utils.full_url(request))}"] ++
        header_parts(request) ++ auth_parts(request) ++ body_parts(request)

    "curl " <> Enum.join(parts, " \\\n  ")
  end

  defp header_parts(request) do
    for row <- request.headers, row.enabled, row.key != "" do
      "--header #{quoted("#{row.key}: #{row.value}")}"
    end
  end

  defp auth_parts(%{auth_type: "bearer", auth_token: token}) when token != "" do
    ["--header #{quoted("Authorization: Bearer #{token}")}"]
  end

  defp auth_parts(%{auth_type: "basic"} = request) do
    ["--user #{quoted("#{request.auth_username}:#{request.auth_password}")}"]
  end

  defp auth_parts(_request), do: []

  defp body_parts(%{body_type: "none"}), do: []
  defp body_parts(%{body: ""}), do: []
  defp body_parts(%{body: body}), do: ["--data #{quoted(body)}"]

  # Single quotes keep the shell out of the way; the only character that needs
  # care inside them is the single quote itself.
  defp quoted(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"

  @doc """
  Parses a curl command into attributes for `MDTClient.HttpClient.Utils.new_request/1`.

  Returns `{:error, reason}` when the command cannot be read.
  """
  def from_curl(command) do
    with {:ok, tokens} <- tokenize(String.trim(command)),
         {:ok, tokens} <- expect_curl(tokens) do
      tokens
      |> collect(%{method: nil, url: nil, headers: [], body: nil, json?: false, user: nil})
      |> build()
    end
  end

  defp expect_curl(["$" | rest]), do: expect_curl(rest)
  defp expect_curl(["curl" | rest]), do: {:ok, rest}
  defp expect_curl(_tokens), do: {:error, "the command has to start with `curl`"}

  ## Tokenizer

  defp tokenize(input), do: tokenize(input, [], "", nil)

  defp tokenize("", tokens, current, nil), do: {:ok, Enum.reverse(push(tokens, current))}

  defp tokenize("", _tokens, _current, _quote),
    do: {:error, "the command has an unbalanced quote"}

  defp tokenize("\\\r\n" <> rest, tokens, current, nil), do: tokenize(rest, tokens, current, nil)
  defp tokenize("\\\n" <> rest, tokens, current, nil), do: tokenize(rest, tokens, current, nil)

  defp tokenize(<<?\\, char::utf8, rest::binary>>, tokens, current, quote) when quote != ?' do
    tokenize(rest, tokens, current <> <<char::utf8>>, quote)
  end

  defp tokenize(<<?', rest::binary>>, tokens, current, nil),
    do: tokenize(rest, tokens, current, ?')

  defp tokenize(<<?', rest::binary>>, tokens, current, ?'),
    do: tokenize(rest, tokens, current, nil)

  defp tokenize(<<?", rest::binary>>, tokens, current, nil),
    do: tokenize(rest, tokens, current, ?")

  defp tokenize(<<?", rest::binary>>, tokens, current, ?"),
    do: tokenize(rest, tokens, current, nil)

  defp tokenize(<<char::utf8, rest::binary>>, tokens, current, nil)
       when char in [?\s, ?\t, ?\n, ?\r] do
    tokenize(rest, push(tokens, current), "", nil)
  end

  defp tokenize(<<char::utf8, rest::binary>>, tokens, current, quote) do
    tokenize(rest, tokens, current <> <<char::utf8>>, quote)
  end

  defp push(tokens, ""), do: tokens
  defp push(tokens, current), do: [current | tokens]

  ## Flags

  defp collect([], acc), do: acc

  defp collect([flag, value | rest], acc) when flag in @method_flags do
    collect(rest, %{acc | method: String.upcase(value)})
  end

  defp collect([<<"-X", method::binary>> | rest], acc) when method != "" do
    collect(rest, %{acc | method: String.upcase(method)})
  end

  defp collect([flag, value | rest], acc) when flag in @header_flags do
    collect(rest, %{acc | headers: acc.headers ++ [value]})
  end

  defp collect([flag, value | rest], acc) when flag in @body_flags do
    body = if acc.body, do: acc.body <> "&" <> value, else: value
    collect(rest, %{acc | body: body, json?: acc.json? or flag == "--json"})
  end

  defp collect([flag, value | rest], acc) when flag in @user_flags do
    collect(rest, %{acc | user: value})
  end

  defp collect([flag, value | rest], acc) when flag in @url_flags do
    collect(rest, %{acc | url: value})
  end

  defp collect([<<"-", _::binary>> = flag, value | rest], acc) do
    # An unknown flag: assume it takes a value, unless that value is the URL.
    if url?(value), do: collect([value | rest], acc), else: collect(rest, put_flag(acc, flag))
  end

  defp collect([<<"-", _::binary>> = flag | rest], acc), do: collect(rest, put_flag(acc, flag))

  defp collect([value | rest], %{url: nil} = acc), do: collect(rest, %{acc | url: value})
  defp collect([_value | rest], acc), do: collect(rest, acc)

  # `-G` moves the body into the query string; everything else we ignore.
  defp put_flag(acc, flag) when flag in ["-G", "--get"], do: %{acc | method: acc.method || "GET"}
  defp put_flag(acc, _flag), do: acc

  defp url?(value) do
    String.contains?(value, "://") or String.starts_with?(value, "www.") or
      (String.contains?(value, ".") and not String.starts_with?(value, "-"))
  end

  ## Request attributes

  defp build(%{url: nil}), do: {:error, "no URL found in the command"}

  defp build(acc) do
    {auth, headers} = acc.headers |> Enum.map(&split_header/1) |> extract_auth(acc.user)
    {url, query} = split_url(acc.url)

    attrs =
      %{
        method: acc.method || if(acc.body, do: "POST", else: "GET"),
        url: url,
        params: Utils.query_rows(query),
        headers:
          Enum.map(headers, fn {key, value} -> Utils.new_row(key, value) end) ++
            [Utils.new_row()],
        body_type: body_type(acc, headers),
        body: acc.body || "",
        editor_tab: if(acc.body, do: "body", else: "params")
      }
      |> Map.merge(auth)

    {:ok, attrs}
  end

  defp split_header(header) do
    case String.split(header, ":", parts: 2) do
      [key, value] -> {String.trim(key), String.trim(value)}
      [key] -> {String.trim(key), ""}
    end
  end

  defp extract_auth(headers, user) do
    {authorization, rest} =
      Enum.split_with(headers, fn {key, _value} -> String.downcase(key) == "authorization" end)

    auth =
      case {authorization, user} do
        {[{_key, "Bearer " <> token} | _], _user} ->
          %{auth_type: "bearer", auth_token: token}

        {[{_key, "Basic " <> encoded} | _], _user} ->
          decoded_basic(encoded) || %{}

        {_headers, user} when is_binary(user) ->
          {username, password} = split_user(user)
          %{auth_type: "basic", auth_username: username, auth_password: password}

        _none ->
          %{}
      end

    # An Authorization header we could not read stays a plain header.
    if auth == %{}, do: {%{}, headers}, else: {auth, rest}
  end

  defp decoded_basic(encoded) do
    with {:ok, decoded} <- Base.decode64(encoded) do
      {username, password} = split_user(decoded)
      %{auth_type: "basic", auth_username: username, auth_password: password}
    else
      :error -> nil
    end
  end

  defp split_user(user) do
    case String.split(user, ":", parts: 2) do
      [username, password] -> {username, password}
      [username] -> {username, ""}
    end
  end

  defp split_url(url) do
    case String.split(url, "?", parts: 2) do
      [base] -> {base, ""}
      [base, query] -> {base, query}
    end
  end

  defp body_type(%{body: nil}, _headers), do: "none"
  defp body_type(%{json?: true}, _headers), do: "json"

  defp body_type(%{body: body}, headers) do
    content_type =
      Enum.find_value(headers, "", fn {key, value} ->
        String.downcase(key) == "content-type" && String.downcase(value)
      end)

    trimmed = String.trim_leading(body)

    cond do
      String.contains?(content_type, "json") -> "json"
      String.starts_with?(trimmed, "{") or String.starts_with?(trimmed, "[") -> "json"
      String.contains?(content_type, "x-www-form-urlencoded") -> "form"
      String.contains?(body, "=") and not String.contains?(body, "\n") -> "form"
      true -> "text"
    end
  end
end
