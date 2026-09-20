defmodule MDTClientWeb.CodeComponents do
  @moduledoc """
  Read-only code viewer.

  Highlighting is done on the server by a small tokenizer: it only knows JSON,
  which covers the payloads the HTTP client shows, and falls back to plain text
  for anything else. Colors come from the Zed theme tokens in `app.css`.
  """
  use Phoenix.Component

  @token ~r/("(?:[^"\\]|\\.)*"\s*:)|("(?:[^"\\]|\\.)*")|(-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)|(\btrue\b|\bfalse\b|\bnull\b)|([\{\}\[\]])|([,:])/

  @doc """
  Renders `content` with line numbers.

  ## Examples

      <.code_block id="response-body" content={@body} language="json" />
  """
  attr :id, :string, required: true
  attr :content, :string, required: true
  attr :language, :string, default: "json", values: ~w(json text)
  attr :class, :any, default: nil

  def code_block(assigns) do
    assigns = assign(assigns, :lines, String.split(assigns.content, "\n"))

    ~H"""
    <div id={@id} class={["overflow-auto bg-deep font-mono text-xs leading-[1.45rem]", @class]}>
      <div class="min-w-max py-1.5">
        <div :for={{line, number} <- Enum.with_index(@lines, 1)} class="flex hover:bg-panel/60">
          <span class="w-10 shrink-0 select-none pr-3 text-right text-ink/40 dark:text-ink/25">{number}</span>
          <code class="whitespace-pre pr-4" phx-no-format><span :for={{class, text} <- tokenize(line, @language)} class={class}>{text}</span></code>
        </div>
      </div>
    </div>
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
