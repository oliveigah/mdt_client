defmodule MDTClientWeb.CodeComponents do
  @moduledoc """
  Read-only code viewer.

  The content is rendered once, as plain text, and the `CodeView` hook in
  `assets/js/code_view.js` takes it from there. JSON is formatted and coloured
  in the browser and only the lines in view are drawn, so a body of many
  megabytes scrolls like a short one. Anything else, and the raw view of JSON,
  is the text as received. Colors come from the Zed theme tokens in `app.css`.
  """
  use Phoenix.Component

  @doc """
  Renders `content` in a viewer that fills the element it is given.

  `format` picks between formatted JSON and the text as received. Changing it
  only updates an attribute, so the content is not sent again; new content
  mounts a new viewer.

  ## Examples

      <.code_block id="response-body" content={@body} language="json" class="flex-1" />
  """
  attr :id, :string, required: true
  attr :content, :string, required: true
  attr :language, :string, default: "json", values: ~w(json text)
  attr :format, :string, default: "pretty", values: ~w(pretty raw)
  attr :class, :any, default: nil

  def code_block(assigns) do
    # The viewer ignores patches to what it drew, so it is keyed by content:
    # another body is another element, and the hook mounts again for it.
    assigns = assign(assigns, :key, :erlang.phash2(assigns.content))

    ~H"""
    <div id={@id} class={["relative overflow-hidden bg-deep", @class]}>
      <div
        id={"#{@id}-#{@key}"}
        phx-hook="CodeView"
        phx-update="ignore"
        data-code-view
        data-language={@language}
        data-format={@format}
        class="absolute inset-0"
      >
        <%!-- Hidden while JSON is formatted, so the browser never lays it out. --%>
        <pre
          data-source
          hidden={@language == "json" and @format == "pretty"}
          class="absolute inset-0 overflow-auto whitespace-pre-wrap break-all px-2.5 py-1.5 font-mono text-xs leading-5 text-ink"
        >{@content}</pre>
      </div>
    </div>
    """
  end

  @doc """
  The language to show a body in: JSON when the content type says so or the
  body opens like a JSON document, text otherwise.

  ## Examples

      iex> MDTClientWeb.CodeComponents.language("application/problem+json", "")
      "json"

      iex> MDTClientWeb.CodeComponents.language(nil, ~s(\\n  [1, 2]))
      "json"

      iex> MDTClientWeb.CodeComponents.language("text/html", "<html>")
      "text"
  """
  def language(content_type, content) do
    cond do
      is_binary(content_type) and String.contains?(content_type, "json") -> "json"
      is_binary(content) and Regex.match?(~r/\A\s*[\[{]/, content) -> "json"
      true -> "text"
    end
  end
end
