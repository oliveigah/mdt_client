defmodule MDTClient.SearchTest do
  use ExUnit.Case, async: true

  alias MDTClient.Search

  test "normalizes the way a Unicode whitespace regex does" do
    # Written as code points: several of these would be invisible in the source.
    for text <- [
          ~c"",
          ~c"   ",
          ~c"  Hello\tWORLD \r\n",
          [?a, 0xA0, 0xA0, ?b],
          [?x, 0x2028, ?y, 0x2029, ?z, 0x85, ?w],
          [?i, 0x3000, ?s, 0x202F, ?n, 0x205F, ?o, 0x180E, ?m, 0x200A, ?h],
          ~c"Straße ÉCOLE"
        ] do
      text = List.to_string(text)
      expected = text |> String.downcase() |> String.replace(~r/\s+/u, " ") |> String.trim()
      assert Search.normalize(text) == expected
    end
  end

  test "a snippet comes from the first text holding a word, read lazily" do
    texts =
      Stream.concat(
        ["nothing here", "the  Payment\tgateway"],
        Stream.repeatedly(fn -> raise "read too far" end)
      )

    assert Search.snippet(texts, ["gateway", "payment"]) == {"the Payment ", "gateway", ""}
    assert Search.snippet(["nothing"], ["gateway"]) == nil
    assert Search.snippet(["gateway"], []) == nil
  end
end
