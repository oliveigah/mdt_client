defmodule MDTClient.DBus.MessageTest do
  use ExUnit.Case, async: true

  alias MDTClient.DBus.Message

  @notify Message.call(
            "org.freedesktop.Notifications",
            "/org/freedesktop/Notifications",
            "org.freedesktop.Notifications",
            "Notify",
            "susssasa{sv}i",
            ["MDT", 0, "", "Title", "Body", ["default", "Open"], %{"urgency" => {"y", 1}}, -1]
          )

  test "reads back a message it wrote, header fields and body" do
    bytes = Message.encode(@notify, 7)
    assert {:ok, message, ""} = Message.decode(bytes)

    assert %Message{
             type: :method_call,
             serial: 7,
             destination: "org.freedesktop.Notifications",
             path: "/org/freedesktop/Notifications",
             member: "Notify",
             signature: "susssasa{sv}i",
             body: [
               "MDT",
               0,
               "",
               "Title",
               "Body",
               ["default", "Open"],
               [{"urgency", {"y", 1}}],
               -1
             ]
           } = message
  end

  test "the body starts on a multiple of 8, as the spec requires" do
    bytes = Message.encode(@notify, 1)
    <<_::binary-size(12), fields_length::little-32, _::binary>> = bytes
    body_start = div(16 + fields_length + 7, 8) * 8
    <<_::binary-size(^body_start), first::little-32, "MDT", 0, _::binary>> = bytes
    assert first == 3
  end

  test "waits for the rest of a message, and leaves the next one in the buffer" do
    one = Message.encode(@notify, 1)
    two = Message.encode(Message.reply(%{@notify | serial: 1, sender: ":1.9"}, "u", [42]), 2)

    assert Message.decode(binary_part(one, 0, 10)) == :more
    assert Message.decode(binary_part(one, 0, byte_size(one) - 1)) == :more

    assert {:ok, %Message{member: "Notify"}, rest} = Message.decode(one <> two)

    assert {:ok, %Message{type: :method_return, reply_serial: 1, destination: ":1.9", body: [42]},
            ""} = Message.decode(rest)
  end

  test "flags and errors survive the trip" do
    error = Message.error(%{@notify | serial: 3, sender: ":1.2"}, "org.example.Nope", "no")
    assert {:ok, decoded, ""} = Message.decode(Message.encode(error, 4))

    assert %Message{type: :error, error_name: "org.example.Nope", body: ["no"], reply_serial: 3} =
             decoded

    quiet = %{@notify | flags: [:no_reply_expected]}

    assert {:ok, %Message{flags: [:no_reply_expected]}, ""} =
             Message.decode(Message.encode(quiet, 5))
  end

  test "refuses bytes that can't start a message" do
    assert {:error, {:byte_order, ?x}} = Message.decode(String.duplicate("x", 16))

    <<head::binary-size(3), _version, rest::binary>> = Message.encode(@notify, 1)
    assert {:error, {:version, 2}} = Message.decode(head <> <<2>> <> rest)

    <<head::binary-size(4), _length::32, rest::binary>> = Message.encode(@notify, 1)
    assert {:error, :too_large} = Message.decode(head <> <<0xFFFFFF00::little-32>> <> rest)
  end

  test "a body that doesn't match its signature is an error, not a crash" do
    # The header says the body is 4 bytes shorter: its last value, an
    # int32, runs past the end.
    <<head::binary-size(4), length::little-32, rest::binary>> = Message.encode(@notify, 1)
    shorter = head <> <<length - 4::little-32>> <> binary_part(rest, 0, byte_size(rest) - 4)
    assert {:error, {:malformed, _}} = Message.decode(shorter)
  end
end
