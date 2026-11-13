defmodule MDTClient.SandboxCorpus do
  @moduledoc """
  Requests a VM can send to a host MDT reads, written to be read two ways:
  malformed ones, and ones two HTTP parsers disagree about. That
  disagreement is how a request gets past a proxy as one thing and reaches
  the host as another (request smuggling), so for each of them MDT must do
  one of two things, and `expect` says which:

    * `{:refused, status}` - MDT answers itself and nothing reaches the host;
    * `:forwarded` - one request reaches the host, with the head MDT wrote;
    * `:forwarded_once` - the same, and what the VM sent behind that request
      reaches the host as it was sent: bytes MDT never wrote a real value
      into, so a second request hidden there has only its placeholder.

  Every entry carries the placeholder of a grant in its `authorization`
  header, as `<<TOKEN>>` in `bytes`, so each is a request that would go out
  with the real value.

  `MDTClient.Sandbox.EgressCorpusTest` runs them through the proxy.
  """

  @host "api.github.com"

  @type entry :: %{
          name: String.t(),
          bytes: binary(),
          expect: :forwarded | :forwarded_once | {:refused, pos_integer()}
        }

  @doc "The host every entry is sent to."
  @spec host() :: String.t()
  def host, do: @host

  @doc "Every entry, with `placeholder` in place."
  @spec entries(String.t()) :: [entry()]
  def entries(placeholder) do
    for {name, bytes, expect} <- raw() do
      %{name: name, bytes: String.replace(bytes, "<<TOKEN>>", placeholder), expect: expect}
    end
  end

  # A request from its lines, ended the way HTTP ends a head.
  defp request(lines, body \\ ""), do: Enum.join(lines, "\r\n") <> "\r\n\r\n" <> body

  defp get(extra), do: request(["GET /user HTTP/1.1", "Host: #{@host}", auth() | extra])

  defp post(extra, body),
    do: request(["POST /x HTTP/1.1", "Host: #{@host}", auth() | extra], body)

  defp auth, do: "Authorization: token <<TOKEN>>"

  defp raw do
    [
      # What an ordinary client sends: these must keep working.
      {"a plain GET", get([]), :forwarded},
      {"a POST with a length", post(["Content-Length: 5"], "hello"), :forwarded},
      {"a POST in chunks", post(["Transfer-Encoding: chunked"], "5\r\nhello\r\n0\r\n\r\n"),
       :forwarded},
      {"header names in any case, values padded with spaces",
       request(["GET /user HTTP/1.1", "HOST:   #{@host}  ", "authorization:\ttoken <<TOKEN>>\t"]),
       :forwarded},
      {"Host with the port", request(["GET /user HTTP/1.1", "Host: #{@host}:443", auth()]),
       :forwarded},
      {"OPTIONS for the whole server", request(["OPTIONS * HTTP/1.1", "Host: #{@host}", auth()]),
       :forwarded},
      {"HTTP/1.0", request(["GET /user HTTP/1.0", "Host: #{@host}", auth()]), :forwarded},
      {"a query, a percent escape and every mark a path may hold",
       request(["GET /a/b%20c;v=1?q=x&y=%7E#frag HTTP/1.1", "Host: #{@host}", auth()]),
       :forwarded},
      {"an expectation of 100 Continue",
       post(["Content-Length: 5", "Expect: 100-continue"], "hello"), :forwarded},

      # How long the body is, said twice or badly.
      {"Content-Length and Transfer-Encoding together",
       post(["Content-Length: 5", "Transfer-Encoding: chunked"], "0\r\n\r\n"), {:refused, 400}},
      {"Content-Length twice, the same",
       post(["Content-Length: 5", "Content-Length: 5"], "hello"), {:refused, 400}},
      {"Content-Length twice, different",
       post(["Content-Length: 5", "Content-Length: 50"], "hello"), {:refused, 400}},
      {"Content-Length as a list", post(["Content-Length: 5, 5"], "hello"), {:refused, 400}},
      {"Content-Length with a sign", post(["Content-Length: +5"], "hello"), {:refused, 400}},
      {"Content-Length negative", post(["Content-Length: -5"], "hello"), {:refused, 400}},
      {"Content-Length in hex", post(["Content-Length: 0x5"], "hello"), {:refused, 400}},
      {"Content-Length with words after", post(["Content-Length: 5 bytes"], "hello"),
       {:refused, 400}},
      {"Content-Length empty", post(["Content-Length:"], "hello"), {:refused, 400}},
      {"Transfer-Encoding twice",
       post(["Transfer-Encoding: chunked", "Transfer-Encoding: chunked"], "0\r\n\r\n"),
       {:refused, 400}},
      {"Transfer-Encoding: chunked, identity",
       post(["Transfer-Encoding: chunked, identity"], "0\r\n\r\n"), {:refused, 400}},
      {"Transfer-Encoding: identity", post(["Transfer-Encoding: identity"], "hello"),
       {:refused, 400}},
      {"Transfer-Encoding: gzip, chunked",
       post(["Transfer-Encoding: gzip, chunked"], "0\r\n\r\n"), {:refused, 400}},
      {"Transfer-Encoding: xchunked", post(["Transfer-Encoding: xchunked"], "0\r\n\r\n"),
       {:refused, 400}},
      {"Transfer-Encoding with a vertical tab before it",
       post(["Transfer-Encoding: \vchunked"], "0\r\n\r\n"), {:refused, 400}},

      # Header lines two parsers split differently.
      {"a space before the colon", post(["Content-Length : 5"], "hello"), {:refused, 400}},
      {"a tab before the colon", post(["Content-Length\t: 5"], "hello"), {:refused, 400}},
      {"a header folded onto a second line",
       request(["GET /user HTTP/1.1", "Host: #{@host}", auth(), "X-A: one", " two"]),
       {:refused, 400}},
      {"a line with no colon", get(["just-a-word"]), {:refused, 400}},
      {"an empty header name", get([": value"]), {:refused, 400}},
      {"a header name with a parenthesis", get(["Con(tent: 1"]), {:refused, 400}},
      {"a header name with bytes outside ASCII", get(["X-Caf\xC3\xA9: 1"]), {:refused, 400}},
      {"a bare line feed between headers",
       "GET /user HTTP/1.1\r\nHost: #{@host}\r\nAuthorization: token <<TOKEN>>\nX-A: 1\r\n\r\n",
       {:refused, 400}},
      {"line feeds alone as line ends",
       "GET /user HTTP/1.1\nHost: #{@host}\nAuthorization: token <<TOKEN>>\n\n", {:refused, 400}},
      {"a bare carriage return in a value", get(["X-A: one\rX-B: two"]), {:refused, 400}},
      {"a NUL in a value", get(["X-A: one\0two"]), {:refused, 400}},
      {"a form feed in a value", get(["X-A: one\ftwo"]), {:refused, 400}},
      {"an escape in a value", get(["X-A: one\e[2Jtwo"]), {:refused, 400}},
      {"a value of bytes outside ASCII, which HTTP allows", get(["X-A: caf\xE9 \xFF"]),
       :forwarded},

      # The request line.
      {"a full address as the target",
       request(["GET http://evil.test/user HTTP/1.1", "Host: #{@host}", auth()]),
       {:refused, 400}},
      {"a host and port as the target",
       request(["GET evil.test:443 HTTP/1.1", "Host: #{@host}", auth()]), {:refused, 400}},
      {"* as the target of a GET", request(["GET * HTTP/1.1", "Host: #{@host}", auth()]),
       {:refused, 400}},
      {"a target with a space in it", request(["GET /a b HTTP/1.1", "Host: #{@host}", auth()]),
       {:refused, 400}},
      {"a target with a tab in it", request(["GET /a\tb HTTP/1.1", "Host: #{@host}", auth()]),
       {:refused, 400}},
      {"a target with a raw byte outside ASCII",
       request(["GET /caf\xE9 HTTP/1.1", "Host: #{@host}", auth()]), {:refused, 400}},
      {"two spaces after the method", request(["GET  /user HTTP/1.1", "Host: #{@host}", auth()]),
       {:refused, 400}},
      {"no version", request(["GET /user", "Host: #{@host}", auth()]), {:refused, 400}},
      {"HTTP/1.2", request(["GET /user HTTP/1.2", "Host: #{@host}", auth()]), {:refused, 400}},
      {"HTTP/2.0", request(["GET /user HTTP/2.0", "Host: #{@host}", auth()]), {:refused, 400}},
      {"the version in small letters", request(["GET /user http/1.1", "Host: #{@host}", auth()]),
       {:refused, 400}},
      {"a method with a byte that isn't a token's",
       request(["G@T /user HTTP/1.1", "Host: #{@host}", auth()]), {:refused, 400}},
      {"an empty line before the request",
       "\r\n" <> request(["GET /user HTTP/1.1", "Host: #{@host}", auth()]), {:refused, 400}},
      {"TRACE", request(["TRACE /user HTTP/1.1", "Host: #{@host}", auth()]), {:refused, 405}},
      {"CONNECT", request(["CONNECT /user HTTP/1.1", "Host: #{@host}", auth()]), {:refused, 405}},

      # Which host it is for.
      {"no Host", request(["GET /user HTTP/1.1", auth()]), {:refused, 400}},
      {"Host twice, the same",
       request(["GET /user HTTP/1.1", "Host: #{@host}", "Host: #{@host}", auth()]),
       {:refused, 400}},
      {"Host twice, different",
       request(["GET /user HTTP/1.1", "Host: #{@host}", "Host: evil.test", auth()]),
       {:refused, 400}},
      {"another Host than the connection's",
       request(["GET /user HTTP/1.1", "Host: evil.test", auth()]), {:refused, 421}},
      {"Host with another port", request(["GET /user HTTP/1.1", "Host: #{@host}:8443", auth()]),
       {:refused, 421}},
      {"Host with a user in front",
       request(["GET /user HTTP/1.1", "Host: evil.test@#{@host}", auth()]), {:refused, 421}},
      {"Host empty", request(["GET /user HTTP/1.1", "Host:", auth()]), {:refused, 421}},

      # A second request hidden behind the first.
      {"a second request behind a body with a length",
       post(["Content-Length: 5"], "hello") <> get(["X-Second: yes"]), :forwarded_once},
      {"a second request behind the last chunk",
       post(["Transfer-Encoding: chunked"], "5\r\nhello\r\n0\r\n\r\n") <>
         get(["X-Second: yes"]), :forwarded_once},
      {"a second request behind a GET", get([]) <> get(["X-Second: yes"]), :forwarded_once},

      # Too much of it.
      {"a head past 64 KiB", get(["X-Pad: " <> String.duplicate("a", 70_000)]), {:refused, 431}},
      {"a head past 64 KiB that never ends",
       "GET /user HTTP/1.1\r\nHost: #{@host}\r\nX-Pad: " <> String.duplicate("a", 70_000),
       {:refused, 431}}
    ]
  end
end
