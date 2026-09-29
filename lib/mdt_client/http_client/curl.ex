defmodule MDTClient.HttpClient.Curl do
  @moduledoc """
  Converts requests to and from `curl` commands.

  `to_curl/1` renders the command the request would run; `from_curl/1` parses a
  pasted command back into request attributes.

  The parser reads the command the way a shell and curl would. Words are split
  with POSIX quoting rules (single, double and `$'...'` quotes, backslash
  escapes and line continuations), and flags are matched against curl's own
  list of options that take an argument, so a switch like `-sS`, `-L` or
  `--compressed` never swallows the word after it. Short switches can be
  bundled (`-sSL`) and a short option can carry its value (`-XPOST`).
  """

  alias MDTClient.HttpClient.Utils

  # Every long option that takes an argument, as listed by `curl --help all`
  # on curl 8.18. Anything missing here is read as a switch.
  @value_options MapSet.new(~w(
    abstract-unix-socket alt-svc aws-sigv4 cacert capath cert cert-type ciphers
    config connect-timeout connect-to continue-at cookie cookie-jar
    create-file-mode crlfile curves data data-ascii data-binary data-raw
    data-urlencode delegation dns-interface dns-ipv4-addr dns-ipv6-addr
    dns-servers doh-url dump-header ech egd-file engine etag-compare etag-save
    expect100-timeout form form-string ftp-account ftp-alternative-to-user
    ftp-method ftp-port ftp-ssl-ccc-mode happy-eyeballs-timeout-ms
    haproxy-clientip header hostpubmd5 hostpubsha256 hsts interface ip-tos
    ipfs-gateway json keepalive-cnt keepalive-time key key-type knownhosts krb
    libcurl limit-rate local-port login-options mail-auth mail-from mail-rcpt
    max-filesize max-redirs max-time netrc-file noproxy oauth2-bearer output
    output-dir parallel-max parallel-max-host pass pinnedpubkey preproxy proto
    proto-default proto-redir proxy proxy-cacert proxy-capath proxy-cert
    proxy-cert-type proxy-ciphers proxy-crlfile proxy-header proxy-key
    proxy-key-type proxy-pass proxy-pinnedpubkey proxy-service-name
    proxy-tls13-ciphers proxy-tlsauthtype proxy-tlspassword proxy-tlsuser
    proxy-user proxy1.0 pubkey quote random-file range rate referer request
    request-target resolve retry retry-delay retry-max-time sasl-authzid
    service-name sigalgs socks4 socks4a socks5 socks5-gssapi-service
    socks5-hostname speed-limit speed-time ssl-sessions stderr telnet-option
    tftp-blksize time-cond tls-max tls13-ciphers tlsauthtype tlspassword tlsuser
    trace trace-ascii trace-config unix-socket upload-file upload-flags url
    url-query user user-agent variable vlan-priority write-out
  ))

  # The short options that take an argument, from the same list.
  @value_shorts ~c"EKCbcdDFPHmoxUQreXYytzTuAw"

  # Short options are read under their long name; only the ones that shape
  # the request need one.
  @short_names %{
    ?A => "user-agent",
    ?b => "cookie",
    ?d => "data",
    ?e => "referer",
    ?F => "form",
    ?G => "get",
    ?H => "header",
    ?I => "head",
    ?m => "max-time",
    ?T => "upload-file",
    ?u => "user",
    ?X => "request"
  }

  @data_options ~w(data data-ascii data-binary data-raw)

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
    with {:ok, words} <- tokenize(String.trim(command)),
         {:ok, words} <- expect_curl(words),
         {:ok, options} <- options(words, []) do
      options
      |> Enum.reduce(new_acc(), &collect/2)
      |> build()
    end
  end

  defp expect_curl(["$" | rest]), do: expect_curl(rest)
  defp expect_curl([curl | rest]) when curl in ["curl", "curl.exe"], do: {:ok, rest}
  defp expect_curl(_words), do: {:error, "the command has to start with `curl`"}

  ## Shell words

  # `current` is nil between words, so an empty quoted word like `''` still
  # counts as one.
  defp tokenize(input), do: tokenize(input, [], nil, nil)

  defp tokenize("", words, current, nil), do: {:ok, Enum.reverse(push(words, current))}
  defp tokenize("", _words, _current, _quote), do: {:error, "the command has an unbalanced quote"}

  # Outside quotes: a backslash, caret (cmd) or backtick (PowerShell) at the
  # end of a line continues the command on the next one.
  defp tokenize(<<cont, ?\r, ?\n, rest::binary>>, words, current, nil) when cont in ~c"\\^`",
    do: tokenize(rest, words, current, nil)

  defp tokenize(<<cont, ?\n, rest::binary>>, words, current, nil) when cont in ~c"\\^`",
    do: tokenize(rest, words, current, nil)

  defp tokenize(<<?\\, char::utf8, rest::binary>>, words, current, nil),
    do: tokenize(rest, words, append(current, <<char::utf8>>), nil)

  defp tokenize(<<?$, ?', rest::binary>>, words, current, nil),
    do: tokenize(rest, words, append(current, ""), :ansi)

  defp tokenize(<<quote, rest::binary>>, words, current, nil) when quote in [?', ?"],
    do: tokenize(rest, words, append(current, ""), quote)

  defp tokenize(<<char, rest::binary>>, words, current, nil) when char in ~c" \t\r\n",
    do: tokenize(rest, push(words, current), nil, nil)

  # A pipe or a command separator ends the curl command.
  defp tokenize(<<char, _rest::binary>>, words, current, nil) when char in ~c"|;",
    do: tokenize("", words, current, nil)

  defp tokenize(<<?&, ?&, _rest::binary>>, words, current, nil),
    do: tokenize("", words, current, nil)

  defp tokenize(<<?#, rest::binary>>, words, nil, nil) do
    case String.split(rest, "\n", parts: 2) do
      [_comment, rest] -> tokenize(rest, words, nil, nil)
      [_comment] -> tokenize("", words, nil, nil)
    end
  end

  # Single quotes take everything literally.
  defp tokenize(<<?', rest::binary>>, words, current, ?'), do: tokenize(rest, words, current, nil)

  # Double quotes only treat a backslash as an escape before these.
  defp tokenize(<<?", rest::binary>>, words, current, ?"), do: tokenize(rest, words, current, nil)

  defp tokenize(<<?\\, ?\n, rest::binary>>, words, current, ?"),
    do: tokenize(rest, words, current, ?")

  defp tokenize(<<?\\, char, rest::binary>>, words, current, ?") when char in ~c"$`\"\\",
    do: tokenize(rest, words, append(current, <<char>>), ?")

  # ANSI-C quoting, as browsers use in "Copy as cURL" when a body has quotes
  # or control characters in it.
  defp tokenize(<<?', rest::binary>>, words, current, :ansi),
    do: tokenize(rest, words, current, nil)

  defp tokenize(<<?\\, rest::binary>>, words, current, :ansi) when rest != "" do
    {text, rest} = ansi_escape(rest)
    tokenize(rest, words, append(current, text), :ansi)
  end

  defp tokenize(<<char::utf8, rest::binary>>, words, current, quote),
    do: tokenize(rest, words, append(current, <<char::utf8>>), quote)

  # Bytes that are not valid UTF-8 are kept as they are.
  defp tokenize(<<byte, rest::binary>>, words, current, quote),
    do: tokenize(rest, words, append(current, <<byte>>), quote)

  @ansi_escapes %{
    ?n => "\n",
    ?t => "\t",
    ?r => "\r",
    ?a => "\a",
    ?b => "\b",
    ?e => "\e",
    ?E => "\e",
    ?f => "\f",
    ?v => "\v",
    ?\\ => "\\",
    ?' => "'",
    ?" => "\"",
    ?? => "?"
  }

  defp ansi_escape(<<char, rest::binary>>) when is_map_key(@ansi_escapes, char),
    do: {Map.fetch!(@ansi_escapes, char), rest}

  defp ansi_escape(<<?x, rest::binary>>), do: ansi_code(rest, 2, 16, "\\x")
  defp ansi_escape(<<?u, rest::binary>>), do: ansi_code(rest, 4, 16, "\\u")
  defp ansi_escape(<<?U, rest::binary>>), do: ansi_code(rest, 8, 16, "\\U")

  defp ansi_escape(<<digit, _::binary>> = rest) when digit in ?0..?7,
    do: ansi_code(rest, 3, 8, "\\")

  defp ansi_escape(<<char, rest::binary>>), do: {<<?\\, char>>, rest}

  # Reads up to `max` digits of a numeric escape. `\x` codes are bytes, the
  # others are code points.
  defp ansi_code(input, max, base, prefix) do
    digits = input |> String.slice(0, max) |> take_digits(base)

    case digits do
      "" ->
        {prefix, input}

      digits ->
        rest = binary_part(input, byte_size(digits), byte_size(input) - byte_size(digits))
        code = String.to_integer(digits, base)
        {ansi_char(code, prefix), rest}
    end
  end

  defp take_digits(input, base) do
    input
    |> String.graphemes()
    |> Enum.take_while(&match?({_value, ""}, Integer.parse(&1, base)))
    |> Enum.join()
  end

  defp ansi_char(code, prefix) when prefix in ["\\x", "\\"] and code < 256, do: <<code>>

  defp ansi_char(code, _prefix) do
    case :unicode.characters_to_binary([code]) do
      binary when is_binary(binary) -> binary
      _invalid -> ""
    end
  end

  defp append(nil, text), do: text
  defp append(current, text), do: current <> text

  defp push(words, nil), do: words
  defp push(words, current), do: [current | words]

  ## Options

  # Turns the words into `{name, value}` pairs under curl's long option names,
  # with `true` for switches and `{:url, value}` for plain words.
  defp options([], acc), do: {:ok, Enum.reverse(acc)}

  defp options(["--" | rest], acc),
    do: {:ok, Enum.reverse(acc, Enum.map(rest, &{:url, &1}))}

  defp options(["--" <> name | rest], acc) do
    if value_option?(name) do
      case rest do
        [value | rest] -> options(rest, [{name, value} | acc])
        [] -> {:error, "`--#{name}` needs a value"}
      end
    else
      options(rest, [{name, true} | acc])
    end
  end

  defp options(["-" <> shorts | rest], acc) when shorts != "", do: shorts(shorts, rest, acc)
  defp options([word | rest], acc), do: options(rest, [{:url, word} | acc])

  # A bundle of short options: switches until the first one that takes a
  # value, which gets the rest of the word or else the next word.
  defp shorts("", rest, acc), do: options(rest, acc)

  defp shorts(<<char::utf8, tail::binary>>, rest, acc) do
    name = Map.get(@short_names, char, <<?-, char::utf8>>)

    cond do
      char not in @value_shorts -> shorts(tail, rest, [{name, true} | acc])
      tail != "" -> options(rest, [{name, tail} | acc])
      rest != [] -> options(tl(rest), [{name, hd(rest)} | acc])
      true -> {:error, "`-#{<<char::utf8>>}` needs a value"}
    end
  end

  # `--expand-data` and friends take the same argument as `--data`.
  defp value_option?("expand-" <> name), do: value_option?(name)
  defp value_option?(name), do: MapSet.member?(@value_options, name)

  ## Request attributes

  defp new_acc do
    %{
      method: nil,
      url: nil,
      headers: [],
      data: [],
      query: [],
      body_kind: nil,
      user: nil,
      bearer: nil,
      get?: false,
      head?: false,
      upload?: false,
      timeout_ms: nil
    }
  end

  defp collect({:url, value}, acc), do: put_url(acc, value)
  defp collect({"url", value}, acc), do: put_url(acc, value)
  defp collect({"request", method}, acc), do: %{acc | method: String.upcase(method)}

  # `@file` reads headers from a file this app cannot see.
  defp collect({"header", "@" <> _file}, acc), do: acc
  defp collect({"header", header}, acc), do: add_header(acc, header)

  defp collect({name, data}, acc) when name in @data_options, do: add_data(acc, data)
  defp collect({"data-urlencode", data}, acc), do: add_data(acc, url_encoded(data), :form)
  defp collect({"json", data}, acc), do: add_data(acc, data, :json)

  # Multipart has no editor of its own, so the fields become a form body.
  defp collect({name, field}, acc) when name in ["form", "form-string"],
    do: add_data(acc, url_encoded(field), :form)

  defp collect({"url-query", "+" <> query}, acc), do: %{acc | query: acc.query ++ [query]}
  defp collect({"url-query", query}, acc), do: %{acc | query: acc.query ++ [url_encoded(query)]}
  defp collect({"user", user}, acc), do: %{acc | user: user}
  defp collect({"oauth2-bearer", token}, acc), do: %{acc | bearer: token}
  defp collect({"user-agent", agent}, acc), do: add_header(acc, "User-Agent: " <> agent)

  defp collect({"referer", referer}, acc),
    do: add_header(acc, "Referer: " <> String.replace_suffix(referer, ";auto", ""))

  # Without a `=` the argument names a cookie file rather than cookies.
  defp collect({"cookie", cookie}, acc) do
    if String.contains?(cookie, "="), do: add_header(acc, "Cookie: " <> cookie), else: acc
  end

  defp collect({"get", true}, acc), do: %{acc | get?: true}
  defp collect({"head", true}, acc), do: %{acc | head?: true}
  defp collect({"upload-file", _file}, acc), do: %{acc | upload?: true}
  defp collect({"max-time", seconds}, acc), do: %{acc | timeout_ms: timeout(seconds)}
  defp collect(_option, acc), do: acc

  # curl takes several URLs; the first one is the request.
  defp put_url(%{url: nil} = acc, url), do: %{acc | url: url}
  defp put_url(acc, _url), do: acc

  defp add_header(acc, header), do: %{acc | headers: acc.headers ++ [header]}

  defp add_data(acc, data, kind \\ nil) do
    %{acc | data: acc.data ++ [data], body_kind: body_kind(acc.body_kind, kind)}
  end

  defp body_kind(:json, _kind), do: :json
  defp body_kind(_current, kind) when not is_nil(kind), do: kind
  defp body_kind(current, _kind), do: current

  # `--data-urlencode` and `--url-query` encode what follows the first `=`,
  # or the whole argument when there is no name.
  defp url_encoded("=" <> content), do: encode(content)

  defp url_encoded(argument) do
    case String.split(argument, "=", parts: 2) do
      [name, content] -> name <> "=" <> encode(content)
      [content] -> encode(content)
    end
  end

  defp encode(content), do: URI.encode(content, &URI.char_unreserved?/1)

  defp timeout(seconds) do
    case Float.parse(seconds) do
      {seconds, ""} when seconds > 0 -> Utils.timeout_value(round(seconds * 1000))
      _invalid -> nil
    end
  end

  defp build(%{url: nil}), do: {:error, "no URL found in the command"}

  defp build(acc) do
    # `-G` sends the data in the query string instead of the body.
    {data, query} = if acc.get?, do: {[], acc.query ++ acc.data}, else: {acc.data, acc.query}
    body = if data == [], do: nil, else: Enum.join(data, "&")
    method = acc.method || default_method(acc, body)

    if method in Utils.methods() do
      {auth, headers} =
        acc.headers |> Enum.map(&split_header/1) |> extract_auth(acc.user, acc.bearer)

      headers = if acc.body_kind == :json, do: put_accept_json(headers), else: headers
      {url, url_query} = acc.url |> with_scheme() |> split_url()

      attrs =
        %{
          method: method,
          url: url,
          params: Utils.query_rows(Enum.join(Enum.reject([url_query | query], &(&1 == "")), "&")),
          headers:
            Enum.map(headers, fn {key, value} -> Utils.new_row(key, value) end) ++
              [Utils.new_row()],
          body_type: body_type(body, acc.body_kind, headers),
          body: body || "",
          editor_tab: if(body, do: "body", else: "params")
        }
        |> Map.merge(auth)
        |> Map.merge(if acc.timeout_ms, do: %{timeout_ms: acc.timeout_ms}, else: %{})

      {:ok, attrs}
    else
      {:error, "the #{method} method is not supported"}
    end
  end

  defp default_method(%{head?: true}, _body), do: "HEAD"
  defp default_method(%{get?: true}, _body), do: "GET"
  defp default_method(%{upload?: true}, _body), do: "PUT"
  defp default_method(_acc, nil), do: "GET"
  defp default_method(_acc, _body), do: "POST"

  # `--json` asks for JSON back as well, unless an Accept header says otherwise.
  defp put_accept_json(headers) do
    if Enum.any?(headers, fn {key, _value} -> String.downcase(key) == "accept" end),
      do: headers,
      else: headers ++ [{"Accept", "application/json"}]
  end

  # curl assumes http:// when the URL has no scheme.
  defp with_scheme(url) do
    if String.contains?(url, "://"), do: url, else: "http://" <> url
  end

  defp split_header(header) do
    case String.split(header, ":", parts: 2) do
      [key, value] -> {String.trim(key), String.trim(value)}
      [key] -> {key |> String.trim() |> String.trim_trailing(";"), ""}
    end
  end

  defp extract_auth(headers, user, bearer) do
    {authorization, rest} =
      Enum.split_with(headers, fn {key, _value} -> String.downcase(key) == "authorization" end)

    auth =
      case {authorization, user, bearer} do
        {[{_key, "Bearer " <> token} | _], _user, _bearer} ->
          %{auth_type: "bearer", auth_token: token}

        {[{_key, "Basic " <> encoded} | _], _user, _bearer} ->
          decoded_basic(encoded) || %{}

        {_headers, user, _bearer} when is_binary(user) ->
          {username, password} = split_user(user)
          %{auth_type: "basic", auth_username: username, auth_password: password}

        {_headers, _user, token} when is_binary(token) ->
          %{auth_type: "bearer", auth_token: token}

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

  defp body_type(nil, _kind, _headers), do: "none"
  defp body_type(_body, :json, _headers), do: "json"
  defp body_type(_body, :form, _headers), do: "form"

  defp body_type(body, nil, headers) do
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
