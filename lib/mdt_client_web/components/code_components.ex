defmodule MDTClientWeb.CodeComponents do
  @moduledoc """
  Read-only code viewer.

  Highlighting is done on the server by a small tokenizer: it only knows JSON,
  which covers the payloads the HTTP client shows, and falls back to plain text
  for anything else. Colors come from the Zed theme tokens in `app.css`.
  """
  use Phoenix.Component

  @token ~r/("(?:[^"\\]|\\.)*"\s*:)|("(?:[^"\\]|\\.)*")|(-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)|(\btrue\b|\bfalse\b|\bnull\b)|([\{\}\[\]])|([,:])/
  @highlight_limit 100_000

  @doc "Whether content is large enough to skip per-token server rendering."
  def large_content?(content) when is_binary(content), do: byte_size(content) > @highlight_limit

  @doc """
  Renders `content` with highlighting and line numbers. Large content uses a
  compact plain-text node to keep rendering responsive.

  ## Examples

      <.code_block id="response-body" content={@body} language="json" />
  """
  attr :id, :string, required: true
  attr :content, :string, required: true
  attr :language, :string, default: "json", values: ~w(json text)
  attr :class, :any, default: nil

  def code_block(assigns) do
    assigns =
      if large_content?(assigns.content) do
        assign(assigns, large?: true, lines: [])
      else
        assign(assigns, large?: false, lines: String.split(assigns.content, "\n"))
      end

    ~H"""
    <%= if @large? do %>
      <pre
        id={@id}
        data-renderer="plain"
        class={[
          "overflow-auto whitespace-pre bg-deep p-2.5 font-mono text-xs leading-[1.45rem] text-ink",
          @class
        ]}
      >{@content}</pre>
    <% else %>
      <div
        id={@id}
        data-renderer="highlighted"
        class={["overflow-auto bg-deep font-mono text-xs leading-[1.45rem]", @class]}
      >
        <div class="min-w-max py-1.5">
          <div :for={{line, number} <- Enum.with_index(@lines, 1)} class="flex hover:bg-panel/60">
            <span class="w-10 shrink-0 select-none pr-3 text-right text-ink/40 dark:text-ink/25">{number}</span>
            <code class="whitespace-pre pr-4" phx-no-format><span :for={{class, text} <- tokenize(line, @language)} class={class}>{text}</span></code>
          </div>
        </div>
      </div>
    <% end %>
    """
  end

  defp tokenize(line, "text"), do: [{"text-ink", line}]

  defp tokenize(line, "json") do
    @token
    |> Regex.split(line, include_captures: true)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&{token_class(&1), &1})
  end

  defp token_class(chunk) do
    trimmed = String.trim(chunk)

    cond do
      String.starts_with?(trimmed, "\"") and String.ends_with?(trimmed, ":") -> "text-syn-key"
      String.starts_with?(trimmed, "\"") -> "text-syn-string"
      trimmed in ~w({ } [ ]) -> "text-syn-brace"
      trimmed in ~w(true false null) -> "text-syn-const"
      trimmed in [",", ":"] -> "text-syn-punct"
      Regex.match?(~r/^-?\d/, trimmed) -> "text-syn-number"
      true -> "text-ink"
    end
  end
end
