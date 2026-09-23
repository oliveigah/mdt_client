defmodule MDTClientWeb.CodeComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias MDTClientWeb.CodeComponents

  test "large bodies use the compact plain-text renderer" do
    body = String.duplicate(~s({"value":"large"}\n), 8_000)

    html =
      render_component(&CodeComponents.code_block/1,
        id: "large-response",
        content: body,
        language: "json"
      )

    document = LazyHTML.from_fragment(html)

    assert document
           |> LazyHTML.query("#large-response")
           |> LazyHTML.attribute("data-renderer") == ["plain"]
  end

  test "small bodies keep syntax highlighting" do
    html =
      render_component(&CodeComponents.code_block/1,
        id: "small-response",
        content: ~s({"ok":true}),
        language: "json"
      )

    document = LazyHTML.from_fragment(html)

    assert document
           |> LazyHTML.query("#small-response")
           |> LazyHTML.attribute("data-renderer") == ["highlighted"]
  end
end
