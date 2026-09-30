defmodule MDTClient.Diagrams.Transfer do
  @moduledoc """
  Exports an identity's diagrams, and imports them back.

  A section is `%{diagrams: [map]}`, oldest change first, each map holding a
  diagram's `:id`, `:title`, `:elements`, `:created_at` and `:updated_at`.
  Plain maps rather than structs, so a file never depends on how the struct
  looks in the build that wrote it; the search text is left out, since it is
  derived and rebuilt on the way back in.

  Diagrams are matched by identifier, which is random and so names the same
  diagram on any installation. New diagrams are added. Where both sides hold
  one, the version saved last wins; should that be the imported one, and the
  version here differs from it, the version here is kept beside it as a copy,
  so merging never loses work done on this side.
  """

  @behaviour MDTClient.Transfer.Participant

  alias MDTClient.Diagrams.Diagram
  alias MDTClient.Diagrams.Library

  @damaged "The diagrams in this file are damaged."

  @impl true
  def key, do: "diagrams.library"

  @impl true
  def label, do: "Diagrams"

  @impl true
  def version, do: 1

  @impl true
  def export(username) do
    diagrams =
      username
      |> Library.all()
      |> Enum.map(&Map.take(&1, [:id, :title, :elements, :created_at, :updated_at]))

    {:ok, %{diagrams: diagrams}}
  end

  @impl true
  def prepare(1, %{diagrams: diagrams}) when is_list(diagrams) do
    diagrams
    |> Enum.reduce_while([], fn diagram, prepared ->
      case prepare_diagram(diagram) do
        {:ok, diagram} -> {:cont, [diagram | prepared]}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      :error -> {:error, @damaged}
      prepared -> {:ok, Enum.reverse(prepared)}
    end
  end

  def prepare(_version, _data), do: {:error, @damaged}

  @impl true
  def describe([]), do: "No diagrams"
  def describe([_diagram]), do: "1 diagram"
  def describe(diagrams), do: "#{length(diagrams)} diagrams"

  @impl true
  def merge(username, diagrams), do: Library.rewrite(username, &combine(&1, diagrams))

  @impl true
  def replace(username, diagrams), do: Library.rewrite(username, fn _current -> diagrams end)

  defp combine(current, imported) do
    here = Map.new(current, &{&1.id, &1})

    imported
    |> Enum.uniq_by(& &1.id)
    |> Enum.reduce(here, fn theirs, diagrams ->
      case Map.fetch(diagrams, theirs.id) do
        :error ->
          Map.put(diagrams, theirs.id, theirs)

        {:ok, mine} ->
          case DateTime.compare(theirs.updated_at, mine.updated_at) do
            :gt -> diagrams |> Map.put(theirs.id, theirs) |> keep_aside(mine, theirs)
            _not_newer -> diagrams
          end
      end
    end)
    |> Map.values()
    |> Enum.sort_by(& &1.updated_at, DateTime)
  end

  # The copy's identifier is derived from the version it keeps, so importing
  # the same file again finds it already there rather than making another.
  defp keep_aside(diagrams, mine, theirs) do
    if mine.title == theirs.title and mine.elements == theirs.elements do
      diagrams
    else
      stamp = DateTime.to_unix(mine.updated_at, :microsecond)
      id = :sha256 |> :crypto.hash("#{mine.id}:#{stamp}") |> binary_part(0, 12)
      copy = %{mine | id: Base.url_encode64(id, padding: false)}
      copy = Diagram.with_search_text(%{copy | title: "#{mine.title} (before import)"})
      Map.put_new(diagrams, copy.id, copy)
    end
  end

  # The timestamps are checked because merging orders and matches by them.
  defp prepare_diagram(
         %{
           id: id,
           title: title,
           elements: elements,
           created_at: %DateTime{},
           updated_at: %DateTime{}
         } = diagram
       )
       when is_binary(title) and is_list(elements) do
    if Diagram.id?(id) do
      {:ok, Diagram.new(Map.take(diagram, [:id, :title, :elements, :created_at, :updated_at]))}
    else
      :error
    end
  end

  defp prepare_diagram(_diagram), do: :error
end
