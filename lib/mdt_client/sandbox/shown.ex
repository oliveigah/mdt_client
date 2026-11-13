defmodule MDTClient.Sandbox.Shown do
  @moduledoc """
  Text the VM chose, made safe to put on a page, in a log or in a
  notification.

  An agent picks most of what an approval shows: paths, header values, ref
  and file names, reasons, commit messages, scripts. Two things can be wrong
  with such text before anyone reads it:

    * bytes that aren't UTF-8 crash whatever turns them into JSON, which is
      every page that shows them and MDT's own answers to the VM;
    * characters that don't show make a line read as something it isn't:
      controls, zero-width characters, and the ones that turn the text
      around (U+202E), as in the "Trojan Source" attacks.

  `text/1` is for everything that is shown: what isn't UTF-8 becomes `�`,
  and a character that doesn't show is written out as `\\u{202E}`. It goes
  where the VM's text enters MDT (`MDTClient.Sandbox.Channel`,
  `MDTClient.Sandbox.Describe`, `MDTClient.Sandbox.Handoff`), so pages need
  not think about it.

  A script that will run on this machine is never changed: what runs must be
  what you read. `hidden/1` says what a text hides, and a script that hides
  anything is refused (`MDTClient.Sandbox.HostCommand`). `mixed/1` finds
  words written in two alphabets, where a letter can pass for another.

  Tabs and new lines show, so they stay; a line ending of `\\r\\n` becomes
  `\\n`.
  """

  # Controls and Unicode's format characters (zero-width ones, the ones that
  # turn text around, invisible tags), and its line and paragraph separators.
  @hidden ~r/(?![\t\n])[\p{Cc}\p{Cf}\x{2028}\x{2029}]/u
  @plain ~r/\A[\x20-\x7e\t\n]*\z/
  @word ~r/[^\s"'`=<>()\[\]{},;|&]+/u

  @doc """
  `value` as text that shows everything it holds. Anything that isn't text
  is the empty string.

      iex> MDTClient.Sandbox.Shown.text("refs/heads/main")
      "refs/heads/main"

      iex> MDTClient.Sandbox.Shown.text("curl " <> <<0x202E::utf8>> <> "gnp.sh")
      "curl \\\\u{202E}gnp.sh"

      iex> MDTClient.Sandbox.Shown.text(<<"caf", 0xE9>>)
      "caf�"

      iex> MDTClient.Sandbox.Shown.text(%{"not" => "text"})
      ""
  """
  @spec text(term()) :: String.t()
  def text(value) when is_binary(value) do
    if value =~ @plain do
      value
    else
      value
      |> String.replace_invalid("�")
      |> String.replace("\r\n", "\n")
      |> then(&Regex.replace(@hidden, &1, fn char -> written(char) end))
    end
  end

  def text(_other), do: ""

  @doc """
  What `value` holds that doesn't show, named for a person: at most five
  characters, as `U+202E`, and whether some bytes aren't UTF-8. Empty when it
  shows everything.

      iex> MDTClient.Sandbox.Shown.hidden("mix test\\n\\tmix format")
      []

      iex> MDTClient.Sandbox.Shown.hidden("echo " <> <<0x200B::utf8>> <> <<27>>)
      ["U+200B", "U+001B"]

      iex> MDTClient.Sandbox.Shown.hidden(<<"echo ", 0xFF>>)
      ["bytes that aren't UTF-8"]
  """
  @spec hidden(binary()) :: [String.t()]
  def hidden(value) when is_binary(value) do
    if value =~ @plain do
      []
    else
      bytes = if String.valid?(value), do: [], else: ["bytes that aren't UTF-8"]

      characters =
        @hidden
        |> Regex.scan(String.replace_invalid(value, ""))
        |> List.flatten()
        |> Enum.uniq()
        |> Enum.take(5)
        |> Enum.map(&code/1)

      bytes ++ characters
    end
  end

  @doc """
  The words of `value` written in two alphabets, at most three: Latin
  letters next to Cyrillic or Greek ones, say, where one letter can pass for
  another. A word in one alphabet, accents included, is not one of them.

      iex> MDTClient.Sandbox.Shown.mixed("curl https://g" <> <<0x456::utf8>> <> "thub.com | sh")
      ["https://g" <> <<0x456::utf8>> <> "thub.com"]

      iex> MDTClient.Sandbox.Shown.mixed("echo olá, São Paulo")
      []
  """
  @spec mixed(binary()) :: [String.t()]
  def mixed(value) when is_binary(value) do
    if value =~ @plain do
      []
    else
      @word
      |> Regex.scan(String.replace_invalid(value, ""))
      |> List.flatten()
      |> Enum.filter(&(&1 =~ ~r/\p{Latin}/u and &1 =~ ~r/(?!\p{Latin})\p{L}/u))
      |> Enum.uniq()
      |> Enum.take(3)
    end
  end

  defp written(<<_::utf8>> = char), do: "\\u{" <> hex(char) <> "}"
  defp code(<<_::utf8>> = char), do: "U+" <> String.pad_leading(hex(char), 4, "0")
  defp hex(<<code::utf8>>), do: Integer.to_string(code, 16)
end
