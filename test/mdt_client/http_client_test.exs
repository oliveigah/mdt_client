defmodule MDTClient.HttpClient.TranslationTest do
  use ExUnit.Case, async: true

  alias MDTClient.HttpClient.HistoryMetadata
  alias MDTClient.HttpClient.Translation
  alias MDTClient.HttpClient.Utils

  test "builds a Req request from editor state" do
    editor_request =
      Utils.new_request(%{
        method: "POST",
        url: "https://api.example.test/orders",
        params: [Utils.new_row("page", "2"), Utils.new_row()],
        headers: [Utils.new_row("X-Trace", "trace-1"), Utils.new_row()],
        body_type: "json",
        body: ~s({"sku":"MDT-PRO"}),
        auth_type: "bearer",
        auth_token: "tok_123"
      })

    request = Translation.to_req(editor_request)

    assert request.method == :post
    assert URI.to_string(request.url) == "https://api.example.test/orders?page=2"
    assert request.body == ~s({"sku":"MDT-PRO"})
    assert request.headers["content-type"] == ["application/json"]
    assert request.headers["x-trace"] == ["trace-1"]
    assert request.headers["authorization"] == ["Bearer tok_123"]
  end

  test "restores a persisted request and renders its Req response" do
    metadata =
      HistoryMetadata.new(%{
        started_at: ~U[2026-09-20 12:00:00Z],
        completed_at: ~U[2026-09-20 12:00:00Z],
        duration_ms: 42,
        description: "Fetch user",
        tags: ["users"]
      })

    request = Req.new(method: :get, url: "https://api.example.test/users/42?expand=teams")

    response = %Req.Response{
      status: 200,
      headers: %{"content-type" => ["application/json"], "x-request-id" => ["req_1"]},
      body: %{"id" => 42, "name" => "Ada"}
    }

    entry = Translation.history_entry({7, metadata, request, response})
    tab = Translation.request_from_history({7, metadata, request, response})

    assert entry.id == "7"
    assert entry.name == "Fetch user"
    assert entry.duration_ms == 42
    assert entry.response.body =~ ~s("name": "Ada")
    assert tab.source_id == "7"
    assert tab.url == "https://api.example.test/users/42"
    assert tab.params |> Enum.map(&{&1.key, &1.value}) == [{"expand", "teams"}, {"", ""}]
    assert tab.response.status == 200
  end
end
