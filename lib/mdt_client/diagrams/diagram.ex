defmodule MDTClient.Diagrams.Diagram do
  @moduledoc """
  One diagram: a title and the elements drawn on its canvas.

  Elements are the string keyed maps the editor in the browser works with,
  `assets/js/diagram_editor.js`, so they travel to it and back without
  translation. Whatever comes in goes through `elements/1` first, which keeps
  only the fields below and only values the editor can draw:

    * `"id"` - unique within the diagram
    * `"type"` - `"rectangle"`, `"ellipse"`, `"diamond"`, `"text"`, `"table"`
      or `"arrow"`
    * `"x"`, `"y"`, `"width"`, `"height"` - the box of anything but an arrow
    * `"x1"`, `"y1"`, `"x2"`, `"y2"` - the ends of an arrow
    * `"start"`, `"end"` - the element each end of an arrow is attached to, or nil
    * `"startRow"`, `"endRow"` - the row of that element, when it is a table
      and the end is attached to one of its rows rather than the whole table
    * `"head"` - which ends of an arrow are drawn with a head: `"end"`,
      `"both"` or `"none"`, for a plain line
    * `"text"` - what is written in a shape, on an arrow, or as free text;
      the title of a table
    * `"rows"` - a table's rows, each a map of `"id"`, unique within the
      table, `"type"` and `"name"`
    * `"split"` - where a table's name column starts, from its left edge
    * `"color"`, `"fill"`, `"stroke"`, `"size"` - the style

  An attached arrow end still carries its coordinates, as last drawn, and a
  table its size, so the diagram reads the same without laying it out again.

  `search_text` is every piece of text in the diagram, title included,
  normalized once when it changes so searching does not walk the elements.
  """

  @types ~w(rectangle ellipse diamond text table arrow)
  @colors ~w(ink accent ok warn bad violet)
  @fills ~w(none tint)
  @strokes ~w(solid dashed)
  @sizes ~w(s m l)
  @heads ~w(end both none)

  @default_title "Untitled diagram"
  @max_title 200
  @max_elements 5_000
  @max_text 10_000
  @max_rows 500
  @max_cell 200
  @max_id 64
  @coordinate_limit 10_000_000
  @snippet_before 24
  @snippet_after 60

  @type element :: %{String.t() => term()}

  @type t :: %__MODULE__{
          id: String.t(),
          title: String.t(),
          elements: [element()],
          created_at: DateTime.t(),
          updated_at: DateTime.t(),
          search_text: String.t()
        }

  defstruct [:id, :created_at, :updated_at, title: @default_title, elements: [], search_text: ""]

  @doc "The title a diagram gets until it is named."
  def default_title, do: @default_title

  @doc "A fresh diagram identifier, safe in a DOM id and a CSS selector."
  @spec new_id() :: String.t()
  def new_id, do: 12 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  @doc "Whether `id` has the shape of a diagram or element identifier."
  @spec id?(term()) :: boolean()
  def id?(id), do: is_binary(id) and byte_size(id) in 1..@max_id and id =~ ~r/\A[\w-]+\z/

  @doc """
  Builds a diagram from `attrs`, as `:id`, `:title`, `:elements`,
  `:created_at` and `:updated_at`; any left out get a sensible default.
  """
  @spec new(map()) :: t()
  def new(attrs \\ %{}) do
    now = DateTime.utc_now()
    created_at = Map.get(attrs, :created_at, now)

    with_search_text(%__MODULE__{
      id: Map.get_lazy(attrs, :id, &new_id/0),
      title: title(Map.get(attrs, :title)),
      elements: elements(Map.get(attrs, :elements, [])),
      created_at: created_at,
      updated_at: Map.get(attrs, :updated_at, created_at)
    })
  end

  @doc """
  Applies a new `:title` or `:elements` to a diagram.

  The diagram is returned as it was when neither changes it, so saving what is
  already there does not bump it to the top of the list.
  """
  @spec update(t(), map()) :: t()
  def update(%__MODULE__{} = diagram, attrs) do
    updated = %{
      diagram
      | title: if(Map.has_key?(attrs, :title), do: title(attrs.title), else: diagram.title),
        elements:
          if(Map.has_key?(attrs, :elements),
            do: elements(attrs.elements),
            else: diagram.elements
          )
    }

    if updated == diagram do
      diagram
    else
      with_search_text(%{updated | updated_at: DateTime.utc_now()})
    end
  end

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
  Keeps the elements the editor can draw, with only the fields it knows.

  Anything unrecognised is dropped rather than refused, so one bad element
  cannot cost the rest of the diagram. Arrows attached to an element that is
  not there come loose, and from a row that is not there fall back to the
  whole table.
  """
  @spec elements(term()) :: [element()]
  def elements(elements) when is_list(elements) do
    elements =
      elements
      |> Enum.take(@max_elements)
      |> Enum.flat_map(&element/1)
      |> Enum.uniq_by(& &1["id"])

    # Every element an arrow can attach to, with the rows it can attach to.
    attachable =
      for %{"type" => type, "id" => id} = element <- elements, type != "arrow", into: %{} do
        {id, element |> Map.get("rows", []) |> MapSet.new(& &1["id"])}
      end

    Enum.map(elements, fn
      %{"type" => "arrow"} = arrow ->
        {start, start_row} = attached(arrow["start"], arrow["startRow"], attachable)
        {finish, end_row} = attached(arrow["end"], arrow["endRow"], attachable)

        %{
          arrow
          | "start" => start,
            "startRow" => start_row,
            "end" => finish,
            "endRow" => end_row
        }

      element ->
        element
    end)
  end

  def elements(_elements), do: []

  @doc """
  Every piece of text written in the diagram, in drawing order. A table
  gives its title and then each row, as its type and name.
  """
  @spec texts(t()) :: [String.t()]
  def texts(%__MODULE__{elements: elements}) do
    for element <- elements, text <- element_texts(element), String.trim(text) != "", do: text
  end

  defp element_texts(%{"type" => "table", "text" => title, "rows" => rows}) do
    [title | Enum.map(rows, &String.trim("#{&1["type"]} #{&1["name"]}"))]
  end

  defp element_texts(%{"text" => text}), do: [text]

  @doc "Rebuilds the text searches run against."
  @spec with_search_text(t()) :: t()
  def with_search_text(%__MODULE__{} = diagram) do
    %{diagram | search_text: [diagram.title | texts(diagram)] |> Enum.join("\n") |> normalize()}
  end

  @doc """
  The words of a search, normalized the way `search_text` is.

  A diagram matches when it holds every word, wherever each one is, since the
  words of one idea are often spread over several boxes.
  """
  @spec terms(String.t()) :: [String.t()]
  def terms(term) when is_binary(term), do: term |> normalize() |> String.split(" ", trim: true)

  @doc "Whether the diagram holds every one of `terms`."
  @spec matches?(t(), [String.t()]) :: boolean()
  def matches?(%__MODULE__{search_text: text}, terms) do
    Enum.all?(terms, &String.contains?(text, &1))
  end

  @doc """
  The first piece of text in the diagram holding one of `terms`, cut down to
  the words around it, as `{before, match, after}`.

  Nil when there are no terms, or when only the title matches — the title is
  on screen already.
  """
  @spec snippet(t(), [String.t()]) :: {String.t(), String.t(), String.t()} | nil
  def snippet(_diagram, []), do: nil

  def snippet(%__MODULE__{} = diagram, terms) do
    patterns = Enum.map(terms, &Regex.compile!(Regex.escape(&1), "iu"))

    Enum.find_value(texts(diagram), fn text ->
      line = String.replace(text, ~r/\s+/u, " ")

      Enum.find_value(patterns, fn pattern ->
        case Regex.run(pattern, line, return: :index) do
          [{at, length}] -> cut(line, at, length)
          nil -> nil
        end
      end)
    end)
  end

  @doc false
  def normalize(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
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

  defp element(%{"id" => id, "type" => type} = attrs) when type in @types do
    if id?(id), do: [build(type, id, attrs)], else: []
  end

  defp element(_attrs), do: []

  defp build("arrow", id, attrs) do
    attrs
    |> common(id, "arrow")
    |> Map.merge(%{
      "x1" => coordinate(attrs["x1"]),
      "y1" => coordinate(attrs["y1"]),
      "x2" => coordinate(attrs["x2"]),
      "y2" => coordinate(attrs["y2"]),
      "start" => attrs["start"],
      "startRow" => attrs["startRow"],
      "end" => attrs["end"],
      "endRow" => attrs["endRow"],
      "head" => one_of(attrs["head"], @heads)
    })
  end

  defp build("table", id, attrs) do
    attrs
    |> build_box(id, "table")
    |> Map.merge(%{"rows" => rows(attrs["rows"]), "split" => extent(attrs["split"])})
  end

  defp build(type, id, attrs), do: build_box(attrs, id, type)

  defp build_box(attrs, id, type) do
    attrs
    |> common(id, type)
    |> Map.merge(%{
      "x" => coordinate(attrs["x"]),
      "y" => coordinate(attrs["y"]),
      "width" => extent(attrs["width"]),
      "height" => extent(attrs["height"])
    })
  end

  defp common(attrs, id, type) do
    %{
      "id" => id,
      "type" => type,
      "text" => text(attrs["text"]),
      "color" => one_of(attrs["color"], @colors),
      "fill" => one_of(attrs["fill"], @fills),
      "stroke" => one_of(attrs["stroke"], @strokes),
      "size" => one_of(attrs["size"], @sizes, "m")
    }
  end

  defp attached(id, row, attachable) do
    case Map.fetch(attachable, id) do
      {:ok, rows} -> {id, if(row in rows, do: row, else: nil)}
      :error -> {nil, nil}
    end
  end

  defp rows(rows) when is_list(rows) do
    rows
    |> Enum.take(@max_rows)
    |> Enum.flat_map(fn
      %{"id" => id} = row ->
        if id?(id),
          do: [%{"id" => id, "type" => cell(row["type"]), "name" => cell(row["name"])}],
          else: []

      _row ->
        []
    end)
    |> Enum.uniq_by(& &1["id"])
  end

  defp rows(_rows), do: []

  # A cell is one line.
  defp cell(text) when is_binary(text) do
    text |> String.replace(~r/[\r\n]+/, " ") |> String.slice(0, @max_cell)
  end

  defp cell(_text), do: ""

  defp one_of(value, allowed, default \\ nil) do
    if value in allowed, do: value, else: default || hd(allowed)
  end

  defp text(text) when is_binary(text) do
    text |> String.replace("\r\n", "\n") |> String.slice(0, @max_text)
  end

  defp text(_text), do: ""

  # Rounded to hundredths: finer than any pointer, and it keeps what the
  # browser sends from growing the file with noise.
  defp coordinate(value) when is_integer(value),
    do: value |> max(-@coordinate_limit) |> min(@coordinate_limit)

  defp coordinate(value) when is_float(value),
    do: value |> Float.round(2) |> max(-@coordinate_limit) |> min(@coordinate_limit)

  defp coordinate(_value), do: 0

  defp extent(value), do: value |> coordinate() |> max(0)
end
