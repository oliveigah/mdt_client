defmodule MDTClient.HttpClient.ResourcesTest do
  use ExUnit.Case, async: false

  alias MDTClient.HttpClient.Resources
  alias MDTClient.HttpClient.HistoryMetadata

  setup do
    Resources.clear()
    on_exit(&Resources.clear/0)
  end

  test "starts with the application and stores history entries" do
    assert Process.whereis(Resources)

    request = Req.new(url: "https://example.test/health")
    response = %Req.Response{status: 204, body: "healthy"}
    metadata = HistoryMetadata.new(%{description: "Health check", tags: ["system", "health"]})

    identifier = Resources.record(metadata, request, response)

    assert {:ok, {^identifier, stored_metadata, ^request, ^response}} = Resources.get(identifier)

    assert %HistoryMetadata{description: "Health check", tags: ["system", "health"]} =
             stored_metadata

    assert stored_metadata.search_text =~ "https://example.test/health"
    assert [{^identifier, ^stored_metadata, ^request, ^response}] = Resources.all()

    assert [{^identifier, ^stored_metadata, ^request, ^response}] = Resources.search("HEALTH")
    assert [{^identifier, ^stored_metadata, ^request, ^response}] = Resources.search("system")
    assert [{^identifier, ^stored_metadata, ^request, ^response}] = Resources.search("healthy")
    assert Resources.search("missing") == []
  end

  test "clears stored history" do
    Resources.record(
      HistoryMetadata.new(%{}),
      Req.new(url: "https://example.test"),
      %Req.Response{status: 200}
    )

    assert :ok = Resources.clear()
    assert Resources.all() == []
  end

  test "restores the counter and records after the owner restarts" do
    first_identifier =
      Resources.record(
        HistoryMetadata.new(%{}),
        Req.new(url: "https://example.test/one"),
        %Req.Response{status: 200}
      )

    last_identifier =
      Resources.record(
        HistoryMetadata.new(%{}),
        Req.new(url: "https://example.test/two"),
        %Req.Response{status: 201}
      )

    previous_owner = Process.whereis(Resources)
    owner_ref = Process.monitor(previous_owner)
    :ok = GenServer.stop(previous_owner, :shutdown)

    assert_receive {:DOWN, ^owner_ref, :process, ^previous_owner, :shutdown}
    _ = :sys.get_state(MDTClient.Supervisor)

    assert Process.whereis(Resources)
    assert {:ok, {^first_identifier, _, _, _}} = Resources.get(first_identifier)
    assert {:ok, {^last_identifier, _, _, _}} = Resources.get(last_identifier)

    next_identifier =
      Resources.record(
        HistoryMetadata.new(%{}),
        Req.new(url: "https://example.test/three"),
        %Req.Response{status: 202}
      )

    assert next_identifier > last_identifier
  end
end
