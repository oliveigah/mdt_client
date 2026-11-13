defmodule MDTClient.Sandbox.RequestView do
  @moduledoc """
  A held request, as you read it on an approval and as you copy it out.

  MDT keeps the request exactly as the VM sent it: the head, and at most the
  first 64 KiB of the body (`MDTClient.Sandbox.Egress.Connection`). The VM
  only ever holds placeholders, so nothing here is a real value. Still, a
  placeholder is noise to a reader, so `marks/1` names each one:

    * on the page, as the grant's name (`headers/2`);
    * in what you copy (`curl/2`, `raw/2`), as a shell variable such as
      `$GH_TOKEN`, so the command is ready for your own token.

  Bodies are shown for what they are (`body/1`): JSON pretty-printed with
  its keys in order, a GraphQL document with its variables, form fields,
  git's pkt-lines, text, or a hex dump of binary data.

  Everything that comes out of here is text that shows all it holds
  (`MDTClient.Sandbox.Shown`): a character that doesn't show is written out,
  on the page and in what you copy, so what you paste into a terminal is
  what you read.
  """

  alias MDTClient.Sandbox.{Grant, Shown}

  @type request :: MDTClient.Sandbox.Approval.request()
  @type mark :: %{placeholder: String.t(), variable: String.t(), label: String.t()}
  @type segment :: {:text, String.t()} | {:mark, String.t()}

  @type body :: %{
          format: :none | :json | :graphql | :form | :git | :text | :binary,
          text: String.t(),
          kept: non_neg_integer(),
          size: non_neg_integer() | nil,
          complete?: boolean()
        }

  # Headers curl sets on its own, or that only mean something to MDT's hop.
  @curl_skips ~w(host content-length connection transfer-encoding expect proxy-connection keep-alive te)
  @hexdump_bytes 512

  @doc "What marks the placeholders of these grants."
  @spec marks([Grant.t()]) :: [mark()]
  def marks(grants) do
    for %Grant{kind: :token, placeholder: placeholder} = grant <- grants,
        is_binary(placeholder),
        do: %{placeholder: placeholder, variable: variable(grant), label: grant.name}
  end

  defp variable(%Grant{env: [first | _]}), do: first

  defp variable(%Grant{id: id}) do
    "TOKEN_" <> (id |> String.upcase() |> String.replace(~r/[^A-Z0-9]+/, "_"))
  end

  @doc "The address the request went to."
  @spec url(request()) :: String.t()
  def url(request), do: Shown.text("https://" <> request.host <> request.path)

  @doc """
  The headers as the page shows them: each value split where a placeholder
  sits, so the page can show the grant's name there. Basic credentials that
  carry one are shown decoded.
  """
  @spec headers(request(), [mark()]) :: [{String.t(), [segment()]}]
  def headers(request, marks) do
    for {name, value} <- request.headers do
      case basic_with_mark(value, marks) do
        {:ok, decoded} ->
          {name, join_text([{:text, "Basic (decoded) "} | segments(decoded, marks)])}

        :error ->
          {name, segments(value, marks)}
      end
    end
  end

  defp join_text([{:text, a}, {:text, b} | rest]), do: join_text([{:text, a <> b} | rest])
  defp join_text([segment | rest]), do: [segment | join_text(rest)]
  defp join_text([]), do: []

  defp segments(value, []), do: [{:text, Shown.text(value)}]

  defp segments(value, [mark | rest]) do
    value
    |> String.split(mark.placeholder)
    |> Enum.map(&segments(&1, rest))
    |> Enum.intersperse([{:mark, mark.label}])
    |> List.flatten()
    |> Enum.reject(&(&1 == {:text, ""}))
  end

  @doc "The body, decoded for reading."
  @spec body(request()) :: body()
  def body(request) do
    {data, complete?} = dechunk(request)
    size = declared_size(request)
    complete? = complete? and (is_nil(size) or size <= byte_size(data))
    type = header(request, "content-type") || ""

    {format, text} =
      cond do
        data == "" ->
          {:none, ""}

        String.contains?(type, "x-git-") ->
          {:git, git(data)}

        json = json(data) ->
          json

        String.contains?(type, "x-www-form-urlencoded") and printable?(data) ->
          {:form, form(data)}

        printable?(data) ->
          {:text, data}

        true ->
          {:binary, hexdump(data)}
      end

    %{
      format: format,
      text: Shown.text(text),
      kept: byte_size(data),
      size: size,
      complete?: complete?
    }
  end

  @doc """
  The request as HTTP text, for reading elsewhere: placeholders become
  `${VARIABLE}`. A body MDT doesn't hold whole, or that is binary, is
  described instead of included.
  """
  @spec raw(request(), [mark()]) :: String.t()
  def raw(request, marks) do
    head =
      for {name, value} <- request.headers do
        case basic_with_mark(value, marks) do
          {:ok, decoded} -> "#{name}: Basic base64(#{variables(decoded, marks)})"
          :error -> "#{name}: #{variables(value, marks)}"
        end
      end

    body = body(request)

    tail =
      case body do
        %{format: :none} ->
          []

        %{format: :binary} ->
          ["", "[#{size_words(body)} of binary data, not included]"]

        %{complete?: false} ->
          ["", variables(raw_text(request), marks), "[cut: #{cut_words(body)}]"]

        _complete ->
          ["", variables(raw_text(request), marks)]
      end

    Shown.text(
      Enum.join(["#{request.method} #{request.path} HTTP/1.1" | head] ++ tail, "\n") <> "\n"
    )
  end

  @doc """
  A curl command that sends the same request, with your own token in the
  placeholder's variable. A body MDT doesn't hold whole, or that is binary,
  is left out, and a comment says so.
  """
  @spec curl(request(), [mark()]) :: String.t()
  def curl(request, marks) do
    {user, headers} =
      Enum.reduce(request.headers, {nil, []}, fn {name, value}, {user, acc} ->
        cond do
          name in @curl_skips ->
            {user, acc}

          match?({:ok, _}, basic_with_mark(value, marks)) ->
            {:ok, decoded} = basic_with_mark(value, marks)
            {decoded, acc}

          true ->
            {user, ["-H " <> shell("#{name}: #{value}", marks) | acc]}
        end
      end)

    body = body(request)

    {note, data} =
      case body do
        %{format: :none} ->
          {nil, []}

        %{format: :binary} ->
          {"# The body is #{size_words(body)} of binary data and isn't included.", []}

        %{complete?: false} ->
          {"# The body isn't included: #{cut_words(body)}.", []}

        _complete ->
          {nil, ["--data-raw " <> shell(raw_text(request), marks)]}
      end

    method =
      case {request.method, data} do
        {"GET", _} -> []
        {"POST", [_ | _]} -> []
        {method, _} -> ["-X " <> method]
      end

    command =
      Enum.join(
        ["curl " <> shell(url(request), marks)] ++
          method ++
          if(user, do: ["-u " <> shell(user, marks)], else: []) ++
          Enum.reverse(headers) ++ data,
        " \\\n  "
      )

    Shown.text(if note, do: note <> "\n" <> command <> "\n", else: command <> "\n")
  end

  ## Bodies

  # The body as text, de-chunked: what the VM meant to send.
  defp raw_text(request), do: request |> dechunk() |> elem(0)

  defp dechunk(request) do
    if (header(request, "transfer-encoding") || "") =~ ~r/chunked/i,
      do: chunks(request.body, []),
      else: {request.body, true}
  end

  defp chunks(data, acc) do
    with [size_line, rest] <- :binary.split(data, "\r\n"),
         {size, _ext} <- Integer.parse(size_line, 16) do
      case rest do
        _ when size == 0 ->
          {IO.iodata_to_binary(Enum.reverse(acc)), true}

        <<chunk::binary-size(^size), "\r\n", rest::binary>> ->
          chunks(rest, [chunk | acc])

        partial ->
          {IO.iodata_to_binary(
             Enum.reverse([binary_part(partial, 0, min(size, byte_size(partial))) | acc])
           ), false}
      end
    else
      _ -> {IO.iodata_to_binary(Enum.reverse(acc)), false}
    end
  end

  defp json(data) do
    with first when first in ["{", "["] <- data |> String.trim_leading() |> String.first(),
         {:ok, plain} <- Jason.decode(data),
         {:ok, ordered} <- Jason.decode(data, objects: :ordered_objects) do
      case plain do
        %{"query" => query} when is_binary(query) ->
          variables =
            case ordered["variables"] do
              nil -> ""
              vars -> "\n\n# variables\n" <> Jason.encode!(vars, pretty: true)
            end

          name =
            case plain["operationName"] do
              name when is_binary(name) -> "# operation #{name}\n"
              _ -> ""
            end

          {:graphql, name <> String.trim(query) <> variables}

        _other ->
          {:json, Jason.encode!(ordered, pretty: true)}
      end
    else
      _ -> nil
    end
  end

  defp form(data) do
    data
    |> String.split("&", trim: true)
    |> Enum.map_join("\n", fn pair ->
      case String.split(pair, "=", parts: 2) do
        [key, value] -> "#{decode_www(key)} = #{decode_www(value)}"
        [key] -> decode_www(key)
      end
    end)
  end

  defp decode_www(text) do
    URI.decode_www_form(text)
  rescue
    ArgumentError -> text
  end

  # git's pkt-lines: commands and capabilities, then the pack, which is binary.
  defp git(data), do: data |> pkt_lines([]) |> Enum.join("\n")

  defp pkt_lines("PACK" <> _ = pack, acc),
    do: Enum.reverse(["[pack data, #{byte_size(pack)} bytes]" | acc])

  defp pkt_lines("0000" <> rest, acc), do: pkt_lines(rest, ["[flush]" | acc])

  defp pkt_lines(<<hex::binary-size(4), rest::binary>> = data, acc) do
    with {length, ""} when length >= 4 <- Integer.parse(hex, 16),
         <<line::binary-size(^length - 4), rest::binary>> <- rest do
      text =
        case String.split(String.trim_trailing(line, "\n"), <<0>>, parts: 2) do
          [command, capabilities] ->
            "#{printable(command)}\n    capabilities: #{printable(capabilities)}"

          [command] ->
            printable(command)
        end

      pkt_lines(rest, [text | acc])
    else
      _ -> Enum.reverse(["[#{byte_size(data)} more bytes]" | acc])
    end
  end

  defp pkt_lines(rest, acc) when byte_size(rest) > 0,
    do: Enum.reverse(["[#{byte_size(rest)} more bytes]" | acc])

  defp pkt_lines(_rest, acc), do: Enum.reverse(acc)

  defp printable(text), do: if(printable?(text), do: text, else: inspect(text))

  defp printable?(data) do
    String.valid?(data) and not Regex.match?(~r/[\x00-\x08\x0E-\x1F\x7F]/, data)
  end

  defp hexdump(data) do
    shown = binary_part(data, 0, min(byte_size(data), @hexdump_bytes))

    lines =
      for {row, index} <- Enum.with_index(rows(shown)) do
        hex = row |> :binary.bin_to_list() |> Enum.map_join(" ", &pad_hex/1)
        ascii = for <<byte <- row>>, into: "", do: if(byte in 32..126, do: <<byte>>, else: ".")

        String.pad_leading(Integer.to_string(index * 16, 16), 8, "0") <>
          "  " <> String.pad_trailing(hex, 47) <> "  " <> ascii
      end

    more = byte_size(data) - byte_size(shown)
    Enum.join(lines ++ if(more > 0, do: ["… #{more} more bytes"], else: []), "\n")
  end

  defp rows(<<row::binary-size(16), rest::binary>>), do: [row | rows(rest)]
  defp rows(<<>>), do: []
  defp rows(rest), do: [rest]

  defp pad_hex(byte), do: byte |> Integer.to_string(16) |> String.pad_leading(2, "0")

  defp declared_size(request) do
    with value when is_binary(value) <- header(request, "content-length"),
         {size, ""} <- Integer.parse(String.trim(value)) do
      size
    else
      _ -> nil
    end
  end

  defp size_words(%{size: size}) when is_integer(size), do: bytes(size)
  defp size_words(%{kept: kept, complete?: true}), do: bytes(kept)
  defp size_words(%{kept: kept}), do: "more than #{bytes(kept)}"

  defp cut_words(%{size: size, kept: kept}) when is_integer(size),
    do: "MDT keeps the first #{bytes(kept)} of #{bytes(size)}"

  defp cut_words(%{kept: kept}), do: "MDT keeps only the first #{bytes(kept)}"

  defp bytes(n) when n < 1024, do: "#{n} bytes"
  defp bytes(n) when n < 1024 * 1024, do: "#{Float.round(n / 1024, 1)} KiB"
  defp bytes(n), do: "#{Float.round(n / (1024 * 1024), 1)} MiB"

  ## Placeholders

  defp basic_with_mark(value, marks) do
    with ["Basic", encoded] <- String.split(value, " ", parts: 2),
         {:ok, decoded} <- Base.decode64(String.trim(encoded)),
         true <- Enum.any?(marks, &String.contains?(decoded, &1.placeholder)) do
      {:ok, decoded}
    else
      _ -> :error
    end
  end

  defp variables(text, marks) do
    Enum.reduce(marks, text, fn mark, acc ->
      String.replace(acc, mark.placeholder, "${#{mark.variable}}")
    end)
  end

  # Single-quoted shell words, with each placeholder swapped for its
  # variable in double quotes: 'token '"$GH_TOKEN".
  defp shell(text, marks) do
    text
    |> words(marks)
    |> Enum.map_join(fn
      {:text, ""} -> ""
      {:text, literal} -> "'" <> String.replace(literal, "'", ~S('\'')) <> "'"
      {:variable, name} -> ~s("$#{name}")
    end)
    |> case do
      "" -> "''"
      quoted -> quoted
    end
  end

  defp words(text, []), do: [{:text, text}]

  defp words(text, [mark | rest]) do
    text
    |> String.split(mark.placeholder)
    |> Enum.map(&words(&1, rest))
    |> Enum.intersperse([{:variable, mark.variable}])
    |> List.flatten()
  end

  defp header(request, name) do
    case List.keyfind(request.headers, name, 0) do
      {_, value} -> value
      nil -> nil
    end
  end
end
