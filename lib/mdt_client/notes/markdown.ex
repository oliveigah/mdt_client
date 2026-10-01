defmodule MDTClient.Notes.Markdown do
  @moduledoc """
  Renders the Markdown a note is written in to HTML, through `MDEx`.

  It is GitHub flavoured: tables, task lists, strikethrough and bare links
  all work, and a single line break is kept, so a note reads as it was typed.

  Notes are not only typed here, so nothing in one is trusted. Comrak's safe
  mode leaves raw HTML out and empties links to scripts and local files,
  which is what makes the result fit to be put on the page as it is. Links
  open in a new window, which the desktop shell hands to the system browser
  rather than navigating MDT away from itself.
  """

  @options [
    extension: [strikethrough: true, table: true, autolink: true, tasklist: true],
    render: [unsafe: false, hardbreaks: true]
  ]

  @doc "The HTML for `markdown`, safe to render as is."
  @spec to_html(String.t()) :: String.t()
  def to_html(markdown) when is_binary(markdown) do
    markdown
    |> MDEx.to_html!(@options)
    # Every anchor comes from comrak itself: raw HTML is left out and text
    # is escaped, so nothing written in the note can match this.
    |> String.replace("<a href=", ~s(<a target="_blank" rel="noopener noreferrer" href=))
  end
end
