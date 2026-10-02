defmodule MDTClient.HttpClient.CoreTest do
  use ExUnit.Case, async: true

  import MDTClient.VaultHelpers

  alias MDTClient.HttpClient.Core
  alias MDTClient.HttpClient.HistoryMetadata
  alias MDTClient.HttpClient.Resources

  setup {Req.Test, :verify_on_exit!}

  setup do
    unlocked_identity()
  end

  test "executes a Req request", %{username: username} do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/health"

      Plug.Conn.send_resp(conn, 200, "ok")
    end)

    request =
      Req.new(
        url: "https://example.test/health",
        plug: {Req.Test, __MODULE__}
      )

    assert {:ok, response = %Req.Response{status: 200, body: "ok"}} =
             Core.request(username, request, %{
               description: "Service health",
               tags: ["system", "health"]
             })

    assert [{identifier, metadata, ^request, ^response}] = Resources.all(username)

    assert {:ok, {^identifier, ^metadata, ^request, ^response}} =
             Resources.get(username, identifier)

    assert %HistoryMetadata{
             started_at: %DateTime{},
             completed_at: %DateTime{},
             duration_ms: duration_ms,
             description: "Service health",
             tags: ["system", "health"]
           } = metadata

    assert duration_ms >= 0
    assert metadata.search_text =~ "service health"
  end

  test "updates tags and descriptions by history identifier", %{username: username} do
    request = Req.new(url: "https://example.test/health")
    response = %Req.Response{status: 200, body: "healthy"}

    identifier =
      Resources.record(
        username,
        HistoryMetadata.new(%{description: "Health endpoint"}),
        request,
        response
      )

    assert {:ok, {^identifier, metadata, ^request, ^response}} =
             Core.add_tag(username, to_string(identifier), "system")

    assert metadata.tags == ["system"]
    assert Resources.search(username, "system") == [{identifier, metadata, request, response}]

    assert {:ok, {^identifier, metadata, ^request, ^response}} =
             Core.set_description(username, identifier, "Primary health check")

    assert metadata.description == "Primary health check"

    assert Resources.search(username, "primary health") == [
             {identifier, metadata, request, response}
           ]

    assert Resources.search(username, "health endpoint") == []
  end

  test "deletes history entries by identifier", %{username: username} do
    request = Req.new(url: "https://example.test/health")
    response = %Req.Response{status: 200, body: "healthy"}

    kept =
      Resources.record(username, HistoryMetadata.new(%{description: "Kept"}), request, response)

    dropped =
      Resources.record(
        username,
        HistoryMetadata.new(%{description: "Dropped"}),
        request,
        response
      )

    assert {:ok, {^dropped, _metadata, _request, _response}} =
             Core.delete(username, to_string(dropped))

    assert Resources.get(username, dropped) == :error
    assert [{^kept, _metadata, _request, _response}] = Resources.all(username)
    assert Resources.search(username, "dropped") == []
  end

  test "reports unknown and invalid history identifiers", %{username: username} do
    assert {:error, :not_found} = Core.add_tag(username, 99_999, "system")

    assert {:error, :invalid_identifier} =
             Core.set_description(username, "not-an-id", "Health check")

    assert {:error, :not_found} = Core.delete(username, 99_999)
    assert {:error, :invalid_identifier} = Core.delete(username, "not-an-id")
  end
end
