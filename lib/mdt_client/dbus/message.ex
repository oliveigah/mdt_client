defmodule MDTClient.DBus.Message do
  @moduledoc """
  One D-Bus message: a method call, its return or error, or a signal.

  `body` holds the values `signature` describes (`MDTClient.DBus.Wire`).
  `serial` is set by the connection that sends it. A message from the bus
  says who sent it (`sender`, a unique name such as `:1.42`) and, for a
  return or an error, which call it answers (`reply_serial`).
  """

  alias MDTClient.DBus.Wire

  defstruct type: :method_call,
            flags: [],
            serial: nil,
            path: nil,
            interface: nil,
            member: nil,
            error_name: nil,
            reply_serial: nil,
            destination: nil,
            sender: nil,
            signature: "",
            body: []

  @type type :: :method_call | :method_return | :error | :signal
  @type flag :: :no_reply_expected | :no_auto_start

  @type t :: %__MODULE__{
          type: type(),
          flags: [flag()],
          serial: pos_integer() | nil,
          path: String.t() | nil,
          interface: String.t() | nil,
          member: String.t() | nil,
          error_name: String.t() | nil,
          reply_serial: pos_integer() | nil,
          destination: String.t() | nil,
          sender: String.t() | nil,
          signature: String.t(),
          body: [term()]
        }

  @types [method_call: 1, method_return: 2, error: 3, signal: 4]
  @flags [no_reply_expected: 0x1, no_auto_start: 0x2]

  # Header fields: code, the key here, the type of its value.
  @fields [
    {1, :path, "o"},
    {2, :interface, "s"},
    {3, :member, "s"},
    {4, :error_name, "s"},
    {5, :reply_serial, "u"},
    {6, :destination, "s"},
    {7, :sender, "s"},
    {8, :signature, "g"}
  ]

  @header_types [
    :byte,
    :byte,
    :byte,
    :byte,
    :uint32,
    :uint32,
    {:array, {:struct, [:byte, :variant]}}
  ]

  # Nothing MDT receives comes near this; a bigger message means the stream
  # is out of step, or something else is sending.
  @max_size 4 * 1024 * 1024

  @doc "A method call."
  @spec call(String.t(), String.t(), String.t(), String.t(), String.t(), [term()]) :: t()
  def call(destination, path, interface, member, signature \\ "", body \\ []) do
    %__MODULE__{
      type: :method_call,
      destination: destination,
      path: path,
      interface: interface,
      member: member,
      signature: signature,
      body: body
    }
  end

  @doc "The return of `call`, addressed back to its sender."
  @spec reply(t(), String.t(), [term()]) :: t()
  def reply(%__MODULE__{type: :method_call} = call, signature \\ "", body \\ []) do
    %__MODULE__{
      type: :method_return,
      reply_serial: call.serial,
      destination: call.sender,
      signature: signature,
      body: body
    }
  end

  @doc "An error answering `call`."
  @spec error(t(), String.t(), String.t()) :: t()
  def error(%__MODULE__{type: :method_call} = call, name, text) do
    %__MODULE__{
      type: :error,
      error_name: name,
      reply_serial: call.serial,
      destination: call.sender,
      signature: "s",
      body: [text]
    }
  end

  @doc "Writes `message` with `serial`, little-endian."
  @spec encode(t(), pos_integer()) :: binary()
  def encode(%__MODULE__{} = message, serial) when is_integer(serial) and serial > 0 do
    body = Wire.encode(Wire.parse_signature(message.signature), message.body)

    fields =
      for {code, key, signature} <- @fields,
          value = field(message, key),
          do: {code, {signature, value}}

    flags =
      Enum.reduce(message.flags, 0, fn flag, acc ->
        Bitwise.bor(acc, Keyword.fetch!(@flags, flag))
      end)

    header =
      Wire.encode(@header_types, [
        ?l,
        Keyword.fetch!(@types, message.type),
        flags,
        1,
        byte_size(body),
        serial,
        fields
      ])

    pad8(header) <> body
  end

  # An empty signature is left out, as the spec allows.
  defp field(%__MODULE__{signature: ""}, :signature), do: nil
  defp field(message, key), do: Map.fetch!(message, key)

  defp pad8(binary) do
    case rem(byte_size(binary), 8) do
      0 -> binary
      r -> binary <> :binary.copy(<<0>>, 8 - r)
    end
  end

  @doc """
  Reads the first message in `buffer`. `:more` when it hasn't all arrived
  yet; `{:error, reason}` when the bytes can't be a message, which leaves
  the stream unusable.
  """
  @spec decode(binary()) :: {:ok, t(), binary()} | :more | {:error, term()}
  def decode(buffer) when byte_size(buffer) < 16, do: :more

  def decode(<<order, _::binary>> = buffer) when order in [?l, ?B] do
    endian = if order == ?l, do: :little, else: :big
    {[_order, type, flags, version, body_length, serial], _} = fixed(buffer, endian)
    {[fields_length], _} = Wire.decode([:uint32], buffer, 12, endian)
    header_end = Wire.align(16 + fields_length, 8)
    total = header_end + body_length

    cond do
      version != 1 ->
        {:error, {:version, version}}

      total > @max_size ->
        {:error, :too_large}

      byte_size(buffer) < total ->
        :more

      true ->
        <<bytes::binary-size(^total), rest::binary>> = buffer

        try do
          {:ok, read(bytes, endian, type, flags, serial, header_end, body_length), rest}
        rescue
          error in [ArgumentError, MatchError, CaseClauseError, FunctionClauseError] ->
            {:error, {:malformed, Exception.message(error)}}
        end
    end
  end

  def decode(<<order, _::binary>>), do: {:error, {:byte_order, order}}

  defp fixed(buffer, endian),
    do: Wire.decode([:byte, :byte, :byte, :byte, :uint32, :uint32], buffer, 0, endian)

  defp read(bytes, endian, type, flags, serial, header_end, body_length) do
    {[fields], _} = Wire.decode([List.last(@header_types)], bytes, 12, endian)
    known = Map.new(@fields, fn {code, key, _signature} -> {code, key} end)

    attrs =
      for {code, {_signature, value}} <- fields, key = known[code], into: %{}, do: {key, value}

    signature = Map.get(attrs, :signature, "")
    body_bytes = binary_part(bytes, header_end, body_length)
    {body, _} = Wire.decode(Wire.parse_signature(signature), body_bytes, 0, endian)

    struct!(
      __MODULE__,
      Map.merge(attrs, %{
        type: type_name(type),
        flags: for({flag, bit} <- @flags, Bitwise.band(flags, bit) != 0, do: flag),
        serial: serial,
        signature: signature,
        body: body
      })
    )
  end

  # Types the spec may add later are read and passed on as their number.
  defp type_name(number) do
    case List.keyfind(@types, number, 1) do
      {name, ^number} -> name
      nil -> number
    end
  end
end
