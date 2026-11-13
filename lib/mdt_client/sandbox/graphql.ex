defmodule MDTClient.Sandbox.GraphQL do
  @moduledoc """
  Reads enough of a GraphQL document to say what it does: its operations,
  each with its type, its name and the fields it starts with.

  The document is text an agent wrote, and an approval shows facts, so this
  is a tokenizer and not a pattern on the text: a comment, a string, an
  alias or a second operation must not change what the card says. The type
  and the fields are facts. The operation's name is whatever its author
  called it.

  It does not validate. A server refuses a document that isn't valid, so
  only valid ones need reading right; one this can't read has no operations.
  """

  @type operation :: %{kind: String.t(), name: String.t() | nil, fields: [String.t()]}

  @kinds ~w(query mutation subscription)
  @max_spread_depth 5

  @doc """
  The operation a server would run: the one named `operation_name`, or the
  only one when no name is given. `:error` when there is no such single
  operation, which a server refuses too.
  """
  @spec selected(String.t(), String.t() | nil) :: {:ok, operation()} | :error
  def selected(document, operation_name) do
    case {operations(document), operation_name} do
      {[only], name} when name in [nil, ""] -> {:ok, only}
      {_several, name} when name in [nil, ""] -> :error
      {operations, name} -> find(operations, name)
    end
  end

  defp find(operations, name) do
    case Enum.filter(operations, &(&1.name == name)) do
      [operation] -> {:ok, operation}
      _none_or_ambiguous -> :error
    end
  end

  @doc """
  Every operation in the document, in order. `fields` are the fields at the
  top of its selection: for a mutation, what it changes. Aliases are read
  through to the real field, and fragments are followed.
  """
  @spec operations(String.t()) :: [operation()]
  def operations(document) when is_binary(document) do
    {operations, fragments} = document |> tokens([]) |> definitions([], %{})
    for operation <- operations, do: %{operation | fields: expand(operation.fields, fragments, 0)}
  end

  @doc """
  A short digest of the document's tokens: the same for two copies that
  differ only in spacing and comments, different for any other change.
  """
  @spec digest(String.t()) :: String.t()
  def digest(document) when is_binary(document) do
    :sha256
    |> :crypto.hash(:erlang.term_to_binary(tokens(document, [])))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 8)
  end

  ## Definitions

  # `{ ... }` alone is a query.
  defp definitions([{:punct, "{"} | _] = tokens, operations, fragments) do
    {fields, rest} = selection(tokens)
    definitions(rest, [%{kind: "query", name: nil, fields: fields} | operations], fragments)
  end

  defp definitions([{:name, kind} | rest], operations, fragments) when kind in @kinds do
    {name, rest} =
      case rest do
        [{:name, name} | rest] -> {name, rest}
        rest -> {nil, rest}
      end

    {fields, rest} = rest |> header(0) |> selection()
    definitions(rest, [%{kind: kind, name: name, fields: fields} | operations], fragments)
  end

  defp definitions([{:name, "fragment"}, {:name, name} | rest], operations, fragments) do
    {fields, rest} = rest |> header(0) |> selection()
    definitions(rest, operations, Map.put(fragments, name, fields))
  end

  defp definitions([_other | rest], operations, fragments),
    do: definitions(rest, operations, fragments)

  defp definitions([], operations, fragments), do: {Enum.reverse(operations), fragments}

  # Skips variable definitions and directives, up to the selection set.
  # Braces inside parentheses are default values, not the selection.
  defp header([{:punct, "{"} | _] = tokens, 0), do: tokens
  defp header([{:punct, open} | rest], depth) when open in ["(", "["], do: header(rest, depth + 1)

  defp header([{:punct, close} | rest], depth) when close in [")", "]"],
    do: header(rest, max(depth - 1, 0))

  defp header([{:punct, "{"} | rest], depth), do: header(rest, depth + 1)
  defp header([{:punct, "}"} | rest], depth), do: header(rest, max(depth - 1, 0))
  defp header([_token | rest], depth), do: header(rest, depth)
  defp header([], _depth), do: []

  ## A selection set

  # The fields at the top of the selection set `tokens` starts with, and
  # what follows its closing brace. `stack` has one entry per open brace:
  # `:top` where names are fields of the operation itself (its own braces,
  # and an inline fragment's inside them), `:deeper` below a field. `arg` is
  # the depth inside arguments, where braces and names are values.
  defp selection([{:punct, "{"} | rest]), do: selection(rest, [:top], 0, false, [])
  defp selection(tokens), do: {[], tokens}

  defp selection([], _stack, _arg, _inline?, fields), do: {Enum.reverse(fields), []}

  defp selection([{:punct, open} | rest], stack, arg, inline?, fields) when open in ["(", "["],
    do: selection(rest, stack, arg + 1, inline?, fields)

  defp selection([{:punct, close} | rest], stack, arg, inline?, fields)
       when close in [")", "]"],
       do: selection(rest, stack, max(arg - 1, 0), inline?, fields)

  defp selection([{:punct, "{"} | rest], stack, arg, inline?, fields) when arg > 0,
    do: selection(rest, stack, arg + 1, inline?, fields)

  defp selection([{:punct, "}"} | rest], stack, arg, inline?, fields) when arg > 0,
    do: selection(rest, stack, arg - 1, inline?, fields)

  defp selection([_value | rest], stack, arg, inline?, fields) when arg > 0,
    do: selection(rest, stack, arg, inline?, fields)

  defp selection([{:punct, "{"} | rest], [:top | _] = stack, 0, true, fields),
    do: selection(rest, [:top | stack], 0, false, fields)

  defp selection([{:punct, "{"} | rest], stack, 0, _inline?, fields),
    do: selection(rest, [:deeper | stack], 0, false, fields)

  defp selection([{:punct, "}"} | rest], [_last], 0, _inline?, fields),
    do: {Enum.reverse(fields), rest}

  defp selection([{:punct, "}"} | rest], [_closed | stack], 0, _inline?, fields),
    do: selection(rest, stack, 0, false, fields)

  # A directive's name is not a field.
  defp selection([{:punct, "@"}, {:name, _directive} | rest], stack, 0, inline?, fields),
    do: selection(rest, stack, 0, inline?, fields)

  defp selection(
         [{:punct, "..."}, {:name, "on"}, {:name, _type} | rest],
         [:top | _] = stack,
         0,
         _,
         fields
       ),
       do: selection(rest, stack, 0, true, fields)

  defp selection([{:punct, "..."}, {:name, fragment} | rest], [:top | _] = stack, 0, _, fields),
    do: selection(rest, stack, 0, false, [{:spread, fragment} | fields])

  defp selection([{:punct, "..."} | rest], [:top | _] = stack, 0, _inline?, fields),
    do: selection(rest, stack, 0, true, fields)

  defp selection(
         [{:name, _alias}, {:punct, ":"}, {:name, field} | rest],
         [:top | _] = stack,
         0,
         _,
         fields
       ),
       do: selection(rest, stack, 0, false, [field | fields])

  defp selection([{:name, field} | rest], [:top | _] = stack, 0, _inline?, fields),
    do: selection(rest, stack, 0, false, [field | fields])

  defp selection([_token | rest], stack, 0, inline?, fields),
    do: selection(rest, stack, 0, inline?, fields)

  # Replaces each `...Fragment` by the fields that fragment starts with.
  defp expand(fields, fragments, depth) do
    fields
    |> Enum.flat_map(fn
      {:spread, name} when depth < @max_spread_depth ->
        case fragments do
          %{^name => inner} -> expand(inner, fragments, depth + 1)
          _unknown -> ["..." <> name]
        end

      {:spread, name} ->
        ["..." <> name]

      field ->
        [field]
    end)
    |> Enum.uniq()
  end

  ## Tokens

  defp tokens(<<>>, acc), do: Enum.reverse(acc)

  # Ignored between tokens: white space, commas, a byte order mark, comments.
  defp tokens(<<c, rest::binary>>, acc) when c in [?\s, ?\t, ?\n, ?\r, ?,], do: tokens(rest, acc)
  defp tokens(<<0xEF, 0xBB, 0xBF, rest::binary>>, acc), do: tokens(rest, acc)
  defp tokens(<<"#", rest::binary>>, acc), do: tokens(after_line(rest), acc)

  defp tokens(<<"\"\"\"", rest::binary>>, acc) do
    {text, rest} = block_string(rest, [])
    tokens(rest, [{:string, text} | acc])
  end

  defp tokens(<<"\"", rest::binary>>, acc) do
    {text, rest} = string(rest, [])
    tokens(rest, [{:string, text} | acc])
  end

  defp tokens(<<"...", rest::binary>>, acc), do: tokens(rest, [{:punct, "..."} | acc])

  defp tokens(<<c, rest::binary>>, acc) when c in ~c"!$&()[]{}:=@|",
    do: tokens(rest, [{:punct, <<c>>} | acc])

  defp tokens(<<c, _::binary>> = text, acc) when c == ?_ or c in ?A..?Z or c in ?a..?z do
    {name, rest} = take(text, &name_byte?/1, [])
    tokens(rest, [{:name, name} | acc])
  end

  defp tokens(<<c, _::binary>> = text, acc) when c == ?- or c in ?0..?9 do
    {number, rest} = take(text, &number_byte?/1, [])
    tokens(rest, [{:number, number} | acc])
  end

  defp tokens(<<c, rest::binary>>, acc), do: tokens(rest, [{:other, <<c>>} | acc])

  defp name_byte?(c), do: c == ?_ or c in ?A..?Z or c in ?a..?z or c in ?0..?9
  defp number_byte?(c), do: c in ?0..?9 or c in ~c"-+.eE"

  defp take(<<c, rest::binary>>, keep?, acc) do
    if keep?.(c), do: take(rest, keep?, [c | acc]), else: {to_text(acc), <<c, rest::binary>>}
  end

  defp take(<<>>, _keep?, acc), do: {to_text(acc), <<>>}

  defp after_line(<<c, rest::binary>>) when c in [?\n, ?\r], do: rest
  defp after_line(<<_c, rest::binary>>), do: after_line(rest)
  defp after_line(<<>>), do: <<>>

  defp string(<<"\\", c, rest::binary>>, acc), do: string(rest, [c, ?\\ | acc])
  defp string(<<"\"", rest::binary>>, acc), do: {to_text(acc), rest}
  defp string(<<c, rest::binary>>, acc), do: string(rest, [c | acc])
  defp string(<<>>, acc), do: {to_text(acc), <<>>}

  defp block_string(<<"\\\"\"\"", rest::binary>>, acc), do: block_string(rest, [?", ?", ?" | acc])
  defp block_string(<<"\"\"\"", rest::binary>>, acc), do: {to_text(acc), rest}
  defp block_string(<<c, rest::binary>>, acc), do: block_string(rest, [c | acc])
  defp block_string(<<>>, acc), do: {to_text(acc), <<>>}

  defp to_text(reversed), do: reversed |> Enum.reverse() |> :erlang.list_to_binary()
end
