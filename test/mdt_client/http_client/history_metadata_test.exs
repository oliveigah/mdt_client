defmodule MDTClient.HttpClient.HistoryMetadataTest do
  use ExUnit.Case, async: true

  alias MDTClient.HttpClient.HistoryMetadata

  defp search_text(request, response, attrs \\ %{}) do
    attrs
    |> HistoryMetadata.new()
    |> HistoryMetadata.with_search_text(request, response)
    |> Map.fetch!(:search_text)
  end

  test "searches what was sent and what came back, as written" do
    request =
      Req.new(
        method: :post,
        url: "https://api.example.test/orders?page=2",
        headers: [{"X-Tenant", "Acme"}],
        body: ~s({"sku": "MDT-PRO"})
      )

    response = %Req.Response{
      status: 422,
      headers: %{"content-type" => ["application/json"]},
      body: ~s({"error":  "Out of\\nstock"})
    }

    text = search_text(request, response, %{description: "Create order", tags: ["Orders"]})

    for expected <- [
          "create order",
          "orders",
          "post https://api.example.test/orders?page=2",
          "x-tenant: acme",
          ~s({"sku": "mdt-pro"}),
          "422",
          "content-type: application/json",
          ~s({"error": "out of\\nstock"})
        ] do
      assert text =~ expected
    end
  end

  test "leaves out what Req keeps beside the request" do
    text =
      search_text(Req.new(url: "https://example.test", retry: false), %Req.Response{status: 200})

    for word <- ~w(retry steps redirect decompress private finch options) do
      refute text =~ word
    end
  end

  test "failures are searched by their message" do
    error = Req.TransportError.exception(reason: :econnrefused)

    assert search_text(Req.new(url: "https://example.test"), error) =~ "connection refused"
  end

  test "bodies count only as text, and only as far as their first 32 KB" do
    request = Req.new(url: "https://example.test")
    image = %Req.Response{status: 200, body: <<0x89, "PNG", 0, 255, "IHDR">>}
    refute search_text(request, image) =~ "png"

    long = String.duplicate("a", 32_768) <> "needle"
    refute search_text(request, %Req.Response{status: 200, body: long}) =~ "needle"

    # A cut through a character drops what is left of it.
    cut = String.duplicate("a", 32_767) <> "é"
    assert String.valid?(search_text(request, %Req.Response{status: 200, body: cut}))

    decoded = %Req.Response{status: 200, body: %{"status" => "Ready"}}
    assert search_text(request, decoded) =~ ~s("status" => "ready")
  end
end
