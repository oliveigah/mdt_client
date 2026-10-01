defmodule MDTClient.Notes.NoteTest do
  use ExUnit.Case, async: true

  alias MDTClient.Notes.Note

  test "a new note is open, with a default title and an empty body" do
    note = Note.new()

    assert Note.id?(note.id)
    assert note.title == Note.default_title()
    assert note.body == ""
    refute Note.done?(note)
    assert note.updated_at == note.created_at
  end

  test "titles are trimmed and bodies keep what was typed, with Unix line endings" do
    note = Note.new(%{title: "  Ship it  ", body: "first\r\nsecond\n\n"})

    assert note.title == "Ship it"
    assert note.body == "first\nsecond\n\n"
    assert Note.new(%{title: "   "}).title == Note.default_title()
    assert Note.new(%{body: nil}).body == ""
  end

  test "bodies are cut to the longest kept" do
    body = String.duplicate("a", Note.max_body() + 10)

    assert String.length(Note.new(%{body: body}).body) == Note.max_body()
  end

  test "updating to what is already there returns the note untouched" do
    note = Note.new(%{title: "Plan", body: "Steps"})

    assert Note.update(note, %{title: " Plan ", body: "Steps"}) == note
    assert Note.update(note, %{done: false}) == note
  end

  test "marking done stamps when, and reopening clears it" do
    note = Note.new(%{title: "Plan"})

    done = Note.update(note, %{done: true})
    assert Note.done?(done)
    assert done.done_at == done.updated_at
    assert DateTime.compare(done.updated_at, note.updated_at) in [:gt, :eq]

    # Marking it done again keeps when it was first done.
    assert Note.update(done, %{done: true}) == done

    reopened = Note.update(done, %{done: false})
    refute Note.done?(reopened)
  end

  test "searches the title and the body, every word wherever it is" do
    note = Note.new(%{title: "Release checklist", body: "- [ ] Bump the VERSION\n- [ ] Tag it"})

    assert Note.matches?(note, Note.terms("release version"))
    assert Note.matches?(note, Note.terms("TAG checklist"))
    assert Note.matches?(note, [])
    refute Note.matches?(note, Note.terms("release deploy"))
  end

  test "snippets come from the body, never from the title alone" do
    note = Note.new(%{title: "Release", body: "Nothing here\n\nBump the version and tag it"})

    assert Note.snippet(note, ["version"]) == {"Bump the ", "version", " and tag it"}
    assert Note.snippet(note, ["release"]) == nil
    assert Note.snippet(note, []) == nil
  end

  test "the excerpt is the first line that says something, without its Markdown" do
    assert Note.excerpt(Note.new(%{body: "\n\n# Heading\nmore"})) == "Heading"
    assert Note.excerpt(Note.new(%{body: "- [ ] Buy milk"})) == "Buy milk"
    assert Note.excerpt(Note.new(%{body: "> quoted"})) == "quoted"
    assert Note.excerpt(Note.new(%{body: "1. first"})) == "first"
    assert Note.excerpt(Note.new(%{body: "```elixir\nIO.puts(1)\n```"})) == "IO.puts(1)"
    assert Note.excerpt(Note.new(%{body: "---\n**Bold** start"})) == "**Bold** start"
    assert Note.excerpt(Note.new(%{body: "  \n  "})) == nil
  end
end
