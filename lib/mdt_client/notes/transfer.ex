defmodule MDTClient.Notes.Transfer do
  @moduledoc """
  Exports an identity's notes, and imports them back.

  A section is `%{notes: [map]}`, oldest change first, each map holding a
  note's `:id`, `:title`, `:body`, `:done_at`, `:created_at` and
  `:updated_at`. Plain maps rather than structs, so a file never depends on
  how the struct looks in the build that wrote it; the search text is left
  out, since it is derived and rebuilt on the way back in.

  Notes are matched by identifier, which is random and so names the same note
  on any installation. New notes are added. Where both sides hold one, the
  version changed last wins; should that be the imported one, and the version
  here differs from it, the version here is kept beside it as a copy, so
  merging never loses work done on this side.
  """

  @behaviour MDTClient.Transfer.Participant

  alias MDTClient.Notes.Library
  alias MDTClient.Notes.Note

  @damaged "The notes in this file are damaged."
  @fields [:id, :title, :body, :done_at, :created_at, :updated_at]

  @impl true
  def key, do: "notes.library"

  @impl true
  def label, do: "Notes"

  @impl true
  def version, do: 1

  @impl true
  def export(username) do
    {:ok, %{notes: username |> Library.all() |> Enum.map(&Map.take(&1, @fields))}}
  end

  @impl true
  def prepare(1, %{notes: notes}) when is_list(notes) do
    notes
    |> Enum.reduce_while([], fn note, prepared ->
      case prepare_note(note) do
        {:ok, note} -> {:cont, [note | prepared]}
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
  def describe([]), do: "No notes"
  def describe([_note]), do: "1 note"
  def describe(notes), do: "#{length(notes)} notes"

  @impl true
  def merge(username, notes), do: Library.rewrite(username, &combine(&1, notes))

  @impl true
  def replace(username, notes), do: Library.rewrite(username, fn _current -> notes end)

  defp combine(current, imported) do
    here = Map.new(current, &{&1.id, &1})

    imported
    |> Enum.uniq_by(& &1.id)
    |> Enum.reduce(here, fn theirs, notes ->
      case Map.fetch(notes, theirs.id) do
        :error ->
          Map.put(notes, theirs.id, theirs)

        {:ok, mine} ->
          case DateTime.compare(theirs.updated_at, mine.updated_at) do
            :gt -> notes |> Map.put(theirs.id, theirs) |> keep_aside(mine, theirs)
            _not_newer -> notes
          end
      end
    end)
    |> Map.values()
    |> Enum.sort_by(& &1.updated_at, DateTime)
  end

  # The copy's identifier is derived from the version it keeps, so importing
  # the same file again finds it already there rather than making another.
  defp keep_aside(notes, mine, theirs) do
    if {mine.title, mine.body, mine.done_at} == {theirs.title, theirs.body, theirs.done_at} do
      notes
    else
      stamp = DateTime.to_unix(mine.updated_at, :microsecond)
      id = :sha256 |> :crypto.hash("#{mine.id}:#{stamp}") |> binary_part(0, 12)
      copy = %{mine | id: Base.url_encode64(id, padding: false)}
      copy = Note.with_search_text(%{copy | title: "#{mine.title} (before import)"})
      Map.put_new(notes, copy.id, copy)
    end
  end

  # The timestamps are checked because merging orders and matches by them.
  defp prepare_note(
         %{
           id: id,
           title: title,
           body: body,
           done_at: done_at,
           created_at: %DateTime{},
           updated_at: %DateTime{}
         } = note
       )
       when is_binary(title) and is_binary(body) and
              (is_nil(done_at) or is_struct(done_at, DateTime)) do
    if Note.id?(id), do: {:ok, Note.new(Map.take(note, @fields))}, else: :error
  end

  defp prepare_note(_note), do: :error
end
