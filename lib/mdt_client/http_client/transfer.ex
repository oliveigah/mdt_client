defmodule MDTClient.HttpClient.Transfer do
  @moduledoc """
  Exports the HTTP client's request history, and imports it back.

  A section is `%{entries: [{metadata, request, response}]}`, oldest first,
  holding the same terms `MDTClient.HttpClient.Resources` keeps. Identifiers
  are left out, since they only mean something to the table they came from,
  and so is the search text, which is derived and rebuilt on the way back in.

  Merging treats two entries as the same request when they started and
  completed at the same instants, with the same method and URL — timestamps
  carry microseconds, so two different requests all but never match. New
  requests are added; a
  request both sides hold keeps the version here, gaining any tags it lacks
  and the description if it has none. The merged history is ordered by when
  each request completed, so imported requests land among the local ones
  rather than on top of them.
  """

  @behaviour MDTClient.Transfer.Participant

  alias MDTClient.HttpClient.HistoryMetadata
  alias MDTClient.HttpClient.Resources

  @damaged "The request history in this file is damaged."

  @impl true
  def key, do: "http_client.history"

  @impl true
  def label, do: "HTTP request history"

  @impl true
  def version, do: 1

  @impl true
  def export(username) do
    entries =
      username
      |> Resources.all()
      |> Enum.reverse()
      |> Enum.map(fn {_identifier, metadata, request, response} ->
        {%{metadata | search_text: ""}, request, response}
      end)

    {:ok, %{entries: entries}}
  end

  @impl true
  def prepare(1, %{entries: entries}) when is_list(entries) do
    entries
    |> Enum.reduce_while([], fn entry, prepared ->
      case prepare_entry(entry) do
        {:ok, entry} -> {:cont, [entry | prepared]}
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
  def describe([]), do: "No requests"
  def describe([_entry]), do: "1 request"
  def describe(entries), do: "#{length(entries)} requests"

  @impl true
  def merge(username, entries), do: Resources.rewrite(username, &combine(&1, entries))

  @impl true
  def replace(username, entries), do: Resources.rewrite(username, fn _current -> entries end)

  defp combine(current, imported) do
    here = MapSet.new(current, &fingerprint/1)
    {known, new} = Enum.split_with(imported, &(fingerprint(&1) in here))
    known = Enum.group_by(known, &fingerprint/1)

    current =
      Enum.map(current, fn entry ->
        known |> Map.get(fingerprint(entry), []) |> Enum.reduce(entry, &absorb(&2, &1))
      end)

    (current ++ Enum.uniq_by(new, &fingerprint/1))
    |> Enum.sort_by(fn {metadata, _request, _response} -> metadata.completed_at end, DateTime)
  end

  # The same request, whichever installation holds it. The URL is compared as
  # text, since the struct's fields can differ between Elixir versions.
  defp fingerprint({metadata, request, _response}) do
    {metadata.started_at, metadata.completed_at, request.method, URI.to_string(request.url)}
  end

  defp absorb({metadata, request, response} = entry, {theirs, _request, _response}) do
    merged = %{
      metadata
      | tags: Enum.uniq(metadata.tags ++ theirs.tags),
        description: metadata.description || theirs.description
    }

    if merged == metadata,
      do: entry,
      else: {HistoryMetadata.with_search_text(merged, request, response), request, response}
  end

  # Rebuilding the metadata struct fills in any field added since the file was
  # made, so the rest of the app never meets an entry missing one. The
  # timestamps are checked because merging orders and matches by them.
  defp prepare_entry(
         {%HistoryMetadata{started_at: %DateTime{}, completed_at: %DateTime{}} = metadata,
          %Req.Request{} = request, response}
       )
       when is_struct(response, Req.Response) or is_exception(response) do
    metadata =
      HistoryMetadata
      |> struct(Map.from_struct(metadata))
      |> HistoryMetadata.with_search_text(request, response)

    {:ok, {metadata, request, response}}
  end

  defp prepare_entry(_entry), do: :error
end
