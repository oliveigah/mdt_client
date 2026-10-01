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

  @doc "Lowercased, with every run of whitespace turned into one space."
  @spec normalize(String.t()) :: String.t()
  def normalize(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  @doc "The words of a search, normalized the way searched text is."
  @spec terms(String.t()) :: [String.t()]
  def terms(term) when is_binary(term), do: term |> normalize() |> String.split(" ", trim: true)

  @doc "Whether normalized `text` holds every one of `terms`."
  @spec matches?(String.t(), [String.t()]) :: boolean()
  def matches?(text, terms) when is_binary(text) do
    Enum.all?(terms, &String.contains?(text, &1))
  end

  @doc """
  The first of `texts` holding one of `terms`, cut down to the words around
  the match, as `{before, match, after}`. Nil when there are no terms, or
  when no text holds any of them.
  """
  @spec snippet([String.t()], [String.t()]) :: {String.t(), String.t(), String.t()} | nil
  def snippet(_texts, []), do: nil

  def snippet(texts, terms) do
    patterns = Enum.map(terms, &Regex.compile!(Regex.escape(&1), "iu"))

    Enum.find_value(texts, fn text ->
      line = String.replace(text, ~r/\s+/u, " ")

      Enum.find_value(patterns, fn pattern ->
        case Regex.run(pattern, line, return: :index) do
          [{at, length}] -> cut(line, at, length)
          nil -> nil
        end
      end)
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
