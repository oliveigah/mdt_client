defmodule MDTClient.Notes.MarkdownTest do
  use ExUnit.Case, async: true

  alias MDTClient.Notes.Markdown

  test "renders GitHub flavoured Markdown" do
    html =
      Markdown.to_html("""
      # Plan

      - [x] Done
      - [ ] To do

      ~~dropped~~ and **kept**

      | a | b |
      |---|---|
      | 1 | 2 |
      """)

    assert html =~ "<h1>Plan</h1>"
    assert html =~ ~s(<input type="checkbox" checked="" disabled="" /> Done)
    assert html =~ ~s(<input type="checkbox" disabled="" /> To do)
    assert html =~ "<del>dropped</del>"
    assert html =~ "<strong>kept</strong>"
    assert html =~ "<table>"
  end

  test "keeps single line breaks" do
    assert Markdown.to_html("one\ntwo") =~ "one<br />"
  end

  test "leaves raw HTML out and empties links to scripts" do
    html =
      Markdown.to_html("""
      <script>alert(1)</script>

      <img src=x onerror=alert(1)>

      [click](javascript:alert(1)) and `<b>code</b>`
      """)

    refute html =~ "<script"
    refute html =~ "onerror"
    refute html =~ "javascript:"
    assert html =~ "<code>&lt;b&gt;code&lt;/b&gt;</code>"
  end

  test "links open outside the app" do
    html = Markdown.to_html("[docs](https://example.com) and https://elixir-lang.org")

    assert html =~
             ~s(<a target="_blank" rel="noopener noreferrer" href="https://example.com">docs</a>)

    assert html =~
             ~s(<a target="_blank" rel="noopener noreferrer" href="https://elixir-lang.org">)
  end

  test "text that looks like a link is left as text" do
    html = Markdown.to_html(~s(`<a href="x">` and <a href="y">raw</a>))

    refute html =~ ~s(target="_blank")
  end
end
