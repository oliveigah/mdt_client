defmodule MDTClient.Search do
  @moduledoc """
  The word search shared by the tools that keep text: diagrams and notes.

  What can be searched is normalized once, with `normalize/1`, when it
  changes, so searching as someone types compares strings rather than
  rebuilding them. A search is split into words by `terms/1`, and text
  matches when it holds every word, wherever each one is, since the words of
  one idea are often written apart.
  """

  @snippet_before 24
  @snippet_after 60
  # Below this many texts, spreading a search over processes costs more than
  # it saves.
  @parallel_from 500

  # Every character `\s` stands for in a Unicode regex. Splitting on them is
  # several times faster than replacing with that regex, which matters for
  # request bodies tens of kilobytes long, and gives the same text.
  @whitespace Enum.map(
                [0x9, 0xA, 0xB, 0xC, 0xD, 0x20, 0x85, 0xA0, 0x1680, 0x180E] ++
                  Enum.to_list(0x2000..0x200A) ++
                  [0x2028, 0x2029, 0x202F, 0x205F, 0x3000],
                &<<&1::utf8>>
              )

  @doc "Lowercased, with every run of whitespace turned into one space."
  @spec normalize(String.t()) :: String.t()
  def normalize(text) when is_binary(text) do
    text
    |> String.downcase()
    |> :binary.split(@whitespace, [:global, :trim_all])
    |> Enum.join(" ")
  end

  @doc "The words of a search, normalized the way searched text is."
  @spec terms(String.t()) :: [String.t()]
  def terms(term) when is_binary(term), do: term |> normalize() |> String.split(" ", trim: true)

  @doc """
  `Enum.filter/2`, split across the schedulers for a list long enough that
  it pays, keeping the order.

  Searching is mostly reading: a word near the top of each text is found
  quickly, but one that is nowhere, or only near the end, reads every byte,
  and tens of megabytes read on one core is a pause someone notices while
  typing.
  """
  @spec filter([item], (item -> as_boolean(term()))) :: [item] when item: term()
  def filter(items, fun) when length(items) < @parallel_from, do: Enum.filter(items, fun)

  def filter(items, fun) do
    chunk = div(length(items), System.schedulers_online()) + 1

    items
    |> Enum.chunk_every(chunk)
    |> Task.async_stream(&Enum.filter(&1, fun), timeout: :infinity)
    |> Enum.flat_map(fn {:ok, kept} -> kept end)
  end

  @doc "Whether normalized `text` holds every one of `terms`."
  @spec matches?(String.t(), [String.t()]) :: boolean()
  def matches?(text, terms) when is_binary(text) do
    Enum.all?(terms, &String.contains?(text, &1))
  end

  @doc """
  The first of `texts` holding one of `terms`, cut down to the words around
  the match, as `{before, match, after}`. Nil when there are no terms, or
  when no text holds any of them. `texts` can be a stream, read only as far
  as the first match.
  """
  @spec snippet(Enumerable.t(String.t()), [String.t()]) ::
          {String.t(), String.t(), String.t()} | nil
  def snippet(_texts, []), do: nil

  def snippet(texts, terms) do
    patterns = Enum.map(terms, &Regex.compile!(Regex.escape(&1), "iu"))

    Enum.find_value(texts, fn text ->
      # Terms hold no whitespace, so a text holds one exactly when it does
      # with its whitespace collapsed; asking first spares collapsing every
      # text that holds none.
      if Enum.any?(patterns, &Regex.match?(&1, text)) do
        line = String.replace(text, ~r/\s+/u, " ")

        Enum.find_value(patterns, fn pattern ->
          case Regex.run(pattern, line, return: :index) do
            [{at, length}] -> cut(line, at, length)
            nil -> nil
          end
        end)
      end
    end)
  end

  defp cut(line, at, length) do
    before = binary_part(line, 0, at)
    after_match = binary_part(line, at + length, byte_size(line) - at - length)

    before =
      if String.length(before) > @snippet_before,
        do: "…" <> String.slice(before, -@snippet_before, @snippet_before),
        else: before

    after_match =
      if String.length(after_match) > @snippet_after,
        do: String.slice(after_match, 0, @snippet_after) <> "…",
        else: after_match

    {before, binary_part(line, at, length), after_match}
  end
end
