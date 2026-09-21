defmodule MDTClient.HttpClient.ResourcesTest do
  use ExUnit.Case, async: false

  import MDTClient.VaultHelpers

  alias MDTClient.Accounts
  alias MDTClient.HttpClient.HistoryMetadata
  alias MDTClient.HttpClient.Resources
  alias MDTClient.Vault.Store

  setup do
    unlocked_identity()
  end

  test "stores and searches history entries", %{username: username} do
    request = Req.new(url: "https://example.test/health")
    response = %Req.Response{status: 204, body: "healthy"}
    metadata = HistoryMetadata.new(%{description: "Health check", tags: ["system", "health"]})

    identifier = Resources.record(username, metadata, request, response)

    assert {:ok, {^identifier, stored, ^request, ^response}} = Resources.get(username, identifier)
    assert %HistoryMetadata{description: "Health check", tags: ["system", "health"]} = stored
    assert stored.search_text =~ "https://example.test/health"
    assert [{^identifier, ^stored, ^request, ^response}] = Resources.all(username)

    assert [{^identifier, ^stored, _, _}] = Resources.search(username, "HEALTH")
    assert [{^identifier, ^stored, _, _}] = Resources.search(username, "system")
    assert [{^identifier, ^stored, _, _}] = Resources.search(username, "healthy")
    assert Resources.search(username, "missing") == []
  end

  test "clears stored history", %{username: username} do
    Resources.record(
      username,
      HistoryMetadata.new(%{}),
      Req.new(url: "https://example.test"),
      %Req.Response{status: 200}
    )

    assert :ok = Resources.clear(username)
    assert Resources.all(username) == []
  end

  test "deletes one entry and keeps the rest", %{username: username} do
    kept = record(username, "https://example.test/one")
    dropped = record(username, "https://example.test/two")

    assert :ok = Resources.delete(username, dropped)
    assert Resources.delete(username, dropped) == :error
    assert Resources.get(username, dropped) == :error
    assert {:ok, _entry} = Resources.get(username, kept)
  end

  test "survives a lock and unlock, restoring the counter", %{
    username: username,
    password: password
  } do
    first = record(username, "https://example.test/one")
    last = record(username, "https://example.test/two")

    :ok = Store.close(username)
    refute Store.open?(username)

    {:ok, _profile, key} = Accounts.sign_in(username, password)
    :ok = Store.open(username, key)

    assert {:ok, {^first, _, _, _}} = Resources.get(username, first)
    assert {:ok, {^last, _, _, _}} = Resources.get(username, last)
    assert record(username, "https://example.test/three") > last
  end

  test "a recorded entry reaches disk without waiting for shutdown", %{username: username} do
    path = Accounts.store_path(username, "http_history.bin")
    refute File.exists?(path)

    record(username, "https://api.example.test/health")

    # No lock, no clean shutdown: just the debounced flush.
    assert eventually(fn -> File.exists?(path) end)
  end

  test "a tag edit reaches disk too", %{username: username} do
    id = record(username, "https://api.example.test/health")
    path = Accounts.store_path(username, "http_history.bin")
    assert eventually(fn -> File.exists?(path) end)

    before = File.read!(path)
    {:ok, _entry} = MDTClient.HttpClient.Core.add_tag(username, id, "smoke")

    assert eventually(fn -> File.read!(path) != before end)
  end

  test "the history file on disk is encrypted", %{username: username} do
    record(username, "https://api.example.test/health")
    :ok = Resources.clear(username)
    record(username, "https://api.example.test/health")
    :ok = Store.close(username)

    body = username |> Accounts.store_path("http_history.bin") |> File.read!()

    refute String.contains?(body, "api.example.test")
    refute String.contains?(body, "Elixir.Req.Request")
  end

  test "another identity cannot read this one's history", %{username: username} do
    record(username, "https://api.example.test/health")
    other = also_unlock("someone-else")

    assert Resources.all(other) == []
    assert Resources.search(other, "health") == []
  end

  test "reading a locked vault raises rather than falling through", %{username: username} do
    :ok = Store.close(username)

    assert_raise RuntimeError, ~r/locked/, fn -> Resources.all(username) end
  end

  defp eventually(check, attempts \\ 40) do
    cond do
      check.() -> true
      attempts == 0 -> false
      true -> Process.sleep(25) && eventually(check, attempts - 1)
    end
  end

  defp record(username, url) do
    Resources.record(
      username,
      HistoryMetadata.new(%{}),
      Req.new(url: url),
      %Req.Response{status: 200}
    )
  end
end
