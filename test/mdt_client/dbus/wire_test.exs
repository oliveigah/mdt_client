defmodule MDTClient.DBus.WireTest do
  use ExUnit.Case, async: true

  alias MDTClient.DBus.Wire

  doctest Wire

  defp roundtrip(signature, values) do
    types = Wire.parse_signature(signature)
    bytes = Wire.encode(types, values)
    {decoded, stop} = Wire.decode(types, bytes, 0, :little)
    assert stop == byte_size(bytes)
    decoded
  end

  test "writes the spec's layout: strings are length, bytes, NUL; numbers aligned to their size" do
    assert Wire.encode([:string], ["hi"]) == <<2::little-32, "hi", 0>>
    # A byte, then a uint32 padded to 4.
    assert Wire.encode([:byte, :uint32], [7, 1]) == <<7, 0, 0, 0, 1::little-32>>
    # A signature has a one-byte length and no alignment.
    assert Wire.encode([:byte, :signature], [1, "su"]) == <<1, 2, "su", 0>>
    assert Wire.encode([:boolean], [true]) == <<1::little-32>>
  end

  test "an array's length counts its items, not the padding before the first one" do
    # uint32 length 0, then padding to 8 for the struct items: still there when empty.
    assert Wire.encode([{:array, {:struct, [:byte]}}], [[]]) == <<0::32, 0::32>>

    assert Wire.encode([{:array, {:struct, [:byte]}}], [[{1}, {2}]]) ==
             <<9::little-32, 0::32, 1, 0, 0, 0, 0, 0, 0, 0, 2>>
  end

  test "reads back what it writes, for every type it supports" do
    values = [
      255,
      true,
      -2,
      65_535,
      -70_000,
      4_000_000_000,
      -(2 ** 40),
      2 ** 63,
      1.5,
      "ünïcode ✓",
      "/org/freedesktop/Notifications",
      "a{sv}"
    ]

    assert roundtrip("ybnqiuxtdsog", values) == values
  end

  test "dicts are lists of pairs, written in key order from a map; variants carry their signature" do
    hints = %{"urgency" => {"y", 1}, "desktop-entry" => {"s", "MDT"}}

    assert roundtrip("a{sv}", [hints]) == [
             [{"desktop-entry", {"s", "MDT"}}, {"urgency", {"y", 1}}]
           ]

    assert roundtrip("asa(us)v", [["a", "b"], [{1, "x"}, {2, "y"}], {"as", ["n"]}]) ==
             [["a", "b"], [{1, "x"}, {2, "y"}], {"as", ["n"]}]
  end

  test "reads big-endian messages too" do
    bytes = <<2::big-32, "hi", 0, 0, 7::big-32>>
    assert Wire.decode([:string, :uint32], bytes, 0, :big) == {["hi", 7], 12}
  end

  test "refuses values that don't fit, and strings the bus would reject" do
    assert_raise ArgumentError, fn -> Wire.encode([:byte], [256]) end
    assert_raise ArgumentError, fn -> Wire.encode([:uint32], [-1]) end
    assert_raise ArgumentError, fn -> Wire.encode([:string], [<<0xFF>>]) end
    assert_raise ArgumentError, fn -> Wire.encode([:string], ["nul\0inside"]) end
    assert_raise ArgumentError, fn -> Wire.encode([:variant], [{"ss", {"a", "b"}}]) end
    assert_raise ArgumentError, fn -> Wire.encode([:string, :string], ["one"]) end
  end

  test "refuses signatures that aren't valid" do
    for bad <- ["a", "(", "()", "a{vs}", "a{s}", "z", "{sv}x"] do
      assert_raise ArgumentError, fn -> Wire.parse_signature(bad) end
    end
  end

  test "raises on bytes that end before the values do" do
    bytes = Wire.encode([:string], ["hello"])

    assert_raise MatchError, fn ->
      Wire.decode([:string], binary_part(bytes, 0, 6), 0, :little)
    end
  end
end
