defmodule MDTClient.HttpClient.CoreTest do
  use ExUnit.Case, async: false

  alias MDTClient.HttpClient.Core
  alias MDTClient.HttpClient.HistoryMetadata
  alias MDTClient.HttpClient.Resources

  setup {Req.Test, :verify_on_exit!}

  setup do
    Resources.clear()
    on_exit(&Resources.clear/0)
  end

  test "executes a Req request" do
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
             Core.request(request, %{description: "Service health", tags: ["system", "health"]})

    assert [{identifier, metadata, ^request, ^response}] = Resources.all()
    assert {:ok, {^identifier, ^metadata, ^request, ^response}} = Resources.get(identifier)

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

  test "updates tags and descriptions by history identifier" do
    request = Req.new(url: "https://example.test/health")
    response = %Req.Response{status: 200, body: "healthy"}

    identifier =
      Resources.record(HistoryMetadata.new(%{description: "Health endpoint"}), request, response)

    assert {:ok, {^identifier, metadata, ^request, ^response}} =
             Core.add_tag(to_string(identifier), "system")

    assert metadata.tags == ["system"]
    assert Resources.search("system") == [{identifier, metadata, request, response}]

    assert {:ok, {^identifier, metadata, ^request, ^response}} =
             Core.set_description(identifier, "Primary health check")

    assert metadata.description == "Primary health check"
    assert Resources.search("primary health") == [{identifier, metadata, request, response}]
    assert Resources.search("health endpoint") == []
  end

  test "reports unknown and invalid history identifiers" do
    assert {:error, :not_found} = Core.add_tag(99_999, "system")
    assert {:error, :invalid_identifier} = Core.set_description("not-an-id", "Health check")
  end
end
