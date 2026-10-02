defmodule MDTClient.Notes.Note do
  @moduledoc """
  One note: a title, a body written in Markdown, and whether it is done.

  Tasks and ideas are both notes, and either can be marked done, which stamps
  `done_at`; it is nil while the note is open.

  `search_text` is the title and the body, normalized once when they change
  so searching does not redo it for every note on every keystroke, and
  `excerpt` is what `excerpt/1` finds in the body, kept for the same reason:
  a list shows it for every note.
  """

  alias MDTClient.Search

  @default_title "Untitled note"
  @max_title 200
  @max_body 100_000
  @max_id 64
  @max_excerpt 160

  @type t :: %__MODULE__{
          id: String.t(),
          title: String.t(),
          body: String.t(),
          done_at: DateTime.t() | nil,
          created_at: DateTime.t(),
          updated_at: DateTime.t(),
          search_text: String.t(),
          excerpt: String.t() | nil
        }

  defstruct [
    :id,
    :created_at,
    :updated_at,
    :done_at,
    title: @default_title,
    body: "",
    search_text: "",
    excerpt: nil
  ]

  @doc "The title a note gets until it is named."
  def default_title, do: @default_title

  @doc "The longest body kept, in characters."
  def max_body, do: @max_body

  @doc "A fresh note identifier, safe in a DOM id and a CSS selector."
  @spec new_id() :: String.t()
  def new_id, do: 12 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  @doc "Whether `id` has the shape of a note identifier."
  @spec id?(term()) :: boolean()
  def id?(id), do: is_binary(id) and byte_size(id) in 1..@max_id and id =~ ~r/\A[\w-]+\z/

  @doc """
  Builds a note from `attrs`, as `:id`, `:title`, `:body`, `:done_at`,
  `:created_at` and `:updated_at`; any left out get a sensible default.
  """
  @spec new(map()) :: t()
  def new(attrs \\ %{}) do
    now = DateTime.utc_now()
    created_at = Map.get(attrs, :created_at, now)

    note = %__MODULE__{
      id: Map.get_lazy(attrs, :id, &new_id/0),
      title: title(Map.get(attrs, :title)),
      body: body(Map.get(attrs, :body)),
      done_at: Map.get(attrs, :done_at),
      created_at: created_at,
      updated_at: Map.get(attrs, :updated_at, created_at)
    }

    with_search_text(%{note | excerpt: excerpt(note)})
  end

  @doc """
  Applies a new `:title`, `:body` or `:done`, a boolean, to a note.

  The note is returned as it was when none of them changes it, so saving
  what is already there does not bump it to the top of the list, and marking
  a done note done again keeps when it was first done.
  """
  @spec update(t(), map()) :: t()
  def update(%__MODULE__{} = note, attrs) do
    now = DateTime.utc_now()

    updated = %{
      note
      | title: if(Map.has_key?(attrs, :title), do: title(attrs.title), else: note.title),
        body: if(Map.has_key?(attrs, :body), do: body(attrs.body), else: note.body),
        done_at:
          if(Map.has_key?(attrs, :done), do: done_at(note, attrs.done, now), else: note.done_at)
    }

    if updated == note do
      note
    else
      with_search_text(%{updated | updated_at: now, excerpt: excerpt(updated)})
    end
  end

  @doc "Whether the note is done."
  @spec done?(t()) :: boolean()
  def done?(%__MODULE__{done_at: done_at}), do: done_at != nil

  @doc "A trimmed title, or the default one when it is blank."
  @spec title(term()) :: String.t()
  def title(title) when is_binary(title) do
    case title |> String.trim() |> String.slice(0, @max_title) do
      "" -> @default_title
      title -> title
    end
  end

  def title(_title), do: @default_title

  @doc """
  The body as it will be kept: Unix line endings, cut to `max_body/0`.

  It is not trimmed, so what is kept is what the editor shows.
  """
  @spec body(term()) :: String.t()
  def body(body) when is_binary(body) do
    body |> String.replace("\r\n", "\n") |> String.slice(0, @max_body)
  end

  def body(_body), do: ""

  @doc """
  The first line of the body that says something, stripped of the Markdown
  that starts it, to show under the title. Nil when nothing is written.
  """
  @spec excerpt(t()) :: String.t() | nil
  def excerpt(%__MODULE__{body: body}) do
    body
    |> String.splitter("\n")
    |> Enum.find_value(fn line ->
      case line
           |> String.replace(~r/\A\s*(?:[#>]+\s*|[-*+]\s+(?:\[[ xX]\]\s*)?|\d+[.)]\s+)*/u, "")
           |> String.trim() do
        "" -> nil
        # Fences and rules are layout, not content.
        "```" <> _fence -> nil
        "~~~" <> _fence -> nil
        text -> if text =~ ~r/\A[-*_]{3,}\z/, do: nil, else: String.slice(text, 0, @max_excerpt)
      end
    end)
  end

  @doc "Rebuilds the text searches run against."
  @spec with_search_text(t()) :: t()
  def with_search_text(%__MODULE__{} = note) do
    %{note | search_text: Search.normalize(note.title <> "\n" <> note.body)}
  end

  @doc "The words of a search, normalized the way `search_text` is."
  @spec terms(String.t()) :: [String.t()]
  def terms(term), do: Search.terms(term)

  @doc "Whether the note holds every one of `terms`, in its title or body."
  @spec matches?(t(), [String.t()]) :: boolean()
  def matches?(%__MODULE__{search_text: text}, terms), do: Search.matches?(text, terms)

  @doc """
  The first line of the body holding one of `terms`, cut down to the words
  around it, as `{before, match, after}`.

  Nil when there are no terms, or when only the title matches — the title is
  on screen already.
  """
  @spec snippet(t(), [String.t()]) :: {String.t(), String.t(), String.t()} | nil
  def snippet(%__MODULE__{body: body}, terms) do
    # Line by line as they are needed: the match is usually near the top.
    Search.snippet(String.splitter(body, "\n"), terms)
  end

  defp done_at(%__MODULE__{done_at: nil}, true, now), do: now
  defp done_at(%__MODULE__{done_at: done_at}, true, _now), do: done_at
  defp done_at(_note, false, _now), do: nil
end
