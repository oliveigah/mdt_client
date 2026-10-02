defmodule MDTClient.HttpClient.TransferTest do
  use ExUnit.Case, async: true

  import MDTClient.VaultHelpers

  alias MDTClient.HttpClient.HistoryMetadata
  alias MDTClient.HttpClient.Resources
  alias MDTClient.HttpClient.Transfer

  setup do
    unlocked_identity()
  end

  test "merging adds what is new, keeps everything here, and orders it all by time", %{
    username: username
  } do
    record(username, entry("/mine-first", ~U[2026-09-01 10:00:00.000001Z]))
    record(username, entry("/mine-last", ~U[2026-09-03 10:00:00.000001Z]))

    :ok = merge(username, [entry("/theirs", ~U[2026-09-02 10:00:00.000001Z])])

    assert paths(username) == ["/mine-last", "/theirs", "/mine-first"]
  end

  test "a request both sides hold stays as it is here, gaining what it lacks", %{
    username: username
  } do
    at = ~U[2026-09-01 10:00:00.000001Z]
    record(username, entry("/shared", at, %{tags: ["mine"]}))
    record(username, entry("/described", at, %{description: "Mine"}))

    :ok =
      merge(username, [
        entry("/shared", at, %{tags: ["theirs", "mine"], description: "Theirs"}),
        entry("/described", at, %{description: "Theirs"})
      ])

    assert [
             {_, %HistoryMetadata{description: "Mine"}, %{url: %URI{path: "/described"}}, _},
             {_, %HistoryMetadata{description: "Theirs", tags: ["mine", "theirs"]}, _, _}
           ] = Resources.all(username)

    # The search text follows the tags it gained.
    assert [{_, _, %{url: %URI{path: "/shared"}}, _}] = Resources.search(username, "theirs")
  end

  test "merging is idempotent", %{username: username} do
    record(username, entry("/one", ~U[2026-09-01 10:00:00.000001Z], %{tags: ["a"]}))
    record(username, entry("/two", ~U[2026-09-02 10:00:00.000001Z]))
    before = history(username)

    # This identity's own export changes nothing.
    {:ok, own} = Transfer.export(username)
    {:ok, own} = Transfer.prepare(1, own)
    :ok = Transfer.merge(username, own)
    assert history(username) == before

    # Nor does another file, the second time.
    theirs = [entry("/three", ~U[2026-09-03 10:00:00.000001Z])]
    :ok = merge(username, theirs)
    once = history(username)
    :ok = merge(username, theirs)
    assert history(username) == once
  end

  test "requests repeated within the file come in once", %{username: username} do
    repeated = entry("/twice", ~U[2026-09-01 10:00:00.000001Z])

    :ok = merge(username, [repeated, repeated])

    assert paths(username) == ["/twice"]
  end

  test "replacing drops what is here", %{username: username} do
    record(username, entry("/mine", ~U[2026-09-01 10:00:00.000001Z]))

    {:ok, prepared} = Transfer.prepare(1, %{entries: [entry("/theirs", DateTime.utc_now())]})
    :ok = Transfer.replace(username, prepared)

    assert paths(username) == ["/theirs"]
  end

  test "an entry without its timestamps is refused as damaged" do
    {metadata, request, response} = entry("/undated", DateTime.utc_now())
    undated = {%{metadata | completed_at: nil}, request, response}

    assert {:error, _message} = Transfer.prepare(1, %{entries: [undated]})
  end

  defp merge(username, entries) do
    {:ok, prepared} = Transfer.prepare(1, %{entries: entries})
    Transfer.merge(username, prepared)
  end

  defp entry(path, at, attrs \\ %{}) do
    metadata = HistoryMetadata.new(Map.merge(%{started_at: at, completed_at: at}, attrs))
    {metadata, Req.new(url: "https://api.example.test" <> path), %Req.Response{status: 200}}
  end

  defp record(username, {metadata, request, response}) do
    Resources.record(username, metadata, request, response)
  end

  defp history(username) do
    Enum.map(Resources.all(username), fn {_id, metadata, request, _response} ->
      {metadata, URI.to_string(request.url)}
    end)
  end

  defp paths(username) do
    Enum.map(Resources.all(username), fn {_id, _metadata, request, _response} ->
      request.url.path
    end)
  end
end
