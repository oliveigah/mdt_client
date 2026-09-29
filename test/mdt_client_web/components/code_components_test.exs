defmodule MDTClientWeb.CodeComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias MDTClientWeb.CodeComponents

  doctest CodeComponents

  defp render_block(attrs) do
    (&CodeComponents.code_block/1)
    |> render_component(attrs)
    |> LazyHTML.from_fragment()
  end

  test "hands the content to the viewer hook as plain text" do
    document = render_block(id: "response", content: ~s({"ok":true}), language: "json")

    [viewer_id] =
      document |> LazyHTML.query("#response [data-code-view]") |> LazyHTML.attribute("id")

    assert String.starts_with?(viewer_id, "response-")

    viewer = LazyHTML.query(document, "##{viewer_id}")
    assert LazyHTML.attribute(viewer, "phx-hook") == ["CodeView"]
    assert LazyHTML.attribute(viewer, "phx-update") == ["ignore"]
    assert LazyHTML.attribute(viewer, "data-language") == ["json"]
    assert LazyHTML.attribute(viewer, "data-format") == ["pretty"]

    assert document |> LazyHTML.query("[data-source]") |> LazyHTML.text() == ~s({"ok":true})
  end

  test "large bodies are rendered once, without per token markup" do
    body = String.duplicate(~s({"value":"large"}\n), 8_000)
    document = render_block(id: "large", content: body, language: "json")

    assert document |> LazyHTML.query("#large span") |> Enum.count() == 0
    assert document |> LazyHTML.query("[data-source]") |> LazyHTML.text() == body
  end

  test "other content mounts another viewer, another format does not" do
    viewer_id = fn attrs ->
      attrs
      |> render_block()
      |> LazyHTML.query("[data-code-view]")
      |> LazyHTML.attribute("id")
    end

    pretty = viewer_id.(id: "body", content: "[1]", format: "pretty")

    assert viewer_id.(id: "body", content: "[1]", format: "raw") == pretty
    refute viewer_id.(id: "body", content: "[2]", format: "pretty") == pretty
  end
end
