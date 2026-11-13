defmodule MDTClient.DBus.Wire do
  @moduledoc """
  D-Bus's wire format: values written and read by their signature.

  Elixir values per type code:

    * `y` byte, `n` `q` `i` `u` `x` `t` integers, `d` float, `b` boolean;
    * `s` string, `o` object path, `g` signature - binaries, valid UTF-8
      without NUL bytes;
    * `a` - a list; an `a{...}` array is a list of `{key, value}` pairs, and
      a map is accepted when writing;
    * `(...)` - a tuple;
    * `v` - `{signature, value}`, the signature of one complete type.

  Alignment is counted from the start of the binary being written or read.
  That is a message's start for its header, and its body's start for the
  body, which D-Bus always places on a multiple of 8. Little-endian is
  written; both byte orders are read. Unix file descriptors (`h`) aren't
  supported.
  """

  @type type ::
          :byte
          | :boolean
          | :int16
          | :uint16
          | :int32
          | :uint32
          | :int64
          | :uint64
          | :double
          | :string
          | :object_path
          | :signature
          | :variant
          | {:array, type()}
          | {:struct, [type()]}
          | {:dict_entry, type(), type()}

  @type endian :: :little | :big

  # The spec caps arrays at 64 MiB.
  @max_array 64 * 1024 * 1024

  @basic %{
    ?y => :byte,
    ?b => :boolean,
    ?n => :int16,
    ?q => :uint16,
    ?i => :int32,
    ?u => :uint32,
    ?x => :int64,
    ?t => :uint64,
    ?d => :double,
    ?s => :string,
    ?o => :object_path,
    ?g => :signature
  }

  @doc """
  The types of a signature, in order. Raises `ArgumentError` on one that
  isn't valid.

      iex> MDTClient.DBus.Wire.parse_signature("susa{sv}")
      [:string, :uint32, :string, {:array, {:dict_entry, :string, :variant}}]

  """
  @spec parse_signature(String.t()) :: [type()]
  def parse_signature(signature) when is_binary(signature) do
    if byte_size(signature) > 255, do: invalid!(signature)
    parse_all(signature, [], signature)
  end

  defp parse_all("", acc, _signature), do: Enum.reverse(acc)

  defp parse_all(rest, acc, signature) do
    {type, rest} = parse_one(rest, signature)
    parse_all(rest, [type | acc], signature)
  end

  defp parse_one(<<code, rest::binary>>, _signature) when is_map_key(@basic, code),
    do: {Map.fetch!(@basic, code), rest}

  defp parse_one("v" <> rest, _signature), do: {:variant, rest}

  defp parse_one("a{" <> rest, signature) do
    {key, rest} = parse_one(rest, signature)
    if not basic?(key), do: invalid!(signature)
    {value, rest} = parse_one(rest, signature)

    case rest do
      "}" <> rest -> {{:array, {:dict_entry, key, value}}, rest}
      _other -> invalid!(signature)
    end
  end

  defp parse_one("a" <> rest, signature) do
    {type, rest} = parse_one(rest, signature)
    {{:array, type}, rest}
  end

  defp parse_one("(" <> rest, signature), do: parse_fields(rest, [], signature)
  defp parse_one(_other, signature), do: invalid!(signature)

  defp parse_fields(")" <> _rest, [], signature), do: invalid!(signature)
  defp parse_fields(")" <> rest, acc, _signature), do: {{:struct, Enum.reverse(acc)}, rest}

  defp parse_fields(rest, acc, signature) do
    {type, rest} = parse_one(rest, signature)
    parse_fields(rest, [type | acc], signature)
  end

  defp basic?(type), do: type in Map.values(@basic)

  defp invalid!(signature),
    do: raise(ArgumentError, "not a valid D-Bus signature: #{inspect(signature)}")

  @doc """
  Writes `values` as `types`. Raises `ArgumentError` when a value doesn't
  fit its type.
  """
  @spec encode([type()], [term()]) :: binary()
  def encode(types, values) when length(types) == length(values) do
    types
    |> Enum.zip(values)
    |> Enum.reduce(<<>>, fn {type, value}, acc -> put(acc, type, value) end)
  end

  def encode(types, values),
    do: raise(ArgumentError, "#{length(types)} types for #{length(values)} values")

  defp put(acc, :byte, v) when is_integer(v) and v in 0..255, do: acc <> <<v>>

  defp put(acc, :boolean, v) when is_boolean(v),
    do: pad(acc, 4) <> <<if(v, do: 1, else: 0)::little-32>>

  defp put(acc, :int16, v) when is_integer(v) and v in -0x8000..0x7FFF,
    do: pad(acc, 2) <> <<v::little-signed-16>>

  defp put(acc, :uint16, v) when is_integer(v) and v in 0..0xFFFF,
    do: pad(acc, 2) <> <<v::little-16>>

  defp put(acc, :int32, v) when is_integer(v) and v in -0x80000000..0x7FFFFFFF,
    do: pad(acc, 4) <> <<v::little-signed-32>>

  defp put(acc, :uint32, v) when is_integer(v) and v in 0..0xFFFFFFFF,
    do: pad(acc, 4) <> <<v::little-32>>

  defp put(acc, :int64, v)
       when is_integer(v) and v in -0x8000000000000000..0x7FFFFFFFFFFFFFFF,
       do: pad(acc, 8) <> <<v::little-signed-64>>

  defp put(acc, :uint64, v) when is_integer(v) and v in 0..0xFFFFFFFFFFFFFFFF,
    do: pad(acc, 8) <> <<v::little-64>>

  defp put(acc, :double, v) when is_number(v), do: pad(acc, 8) <> <<v * 1.0::little-float-64>>

  defp put(acc, type, v) when type in [:string, :object_path] and is_binary(v) do
    text!(v)
    pad(acc, 4) <> <<byte_size(v)::little-32>> <> v <> <<0>>
  end

  defp put(acc, :signature, v) when is_binary(v) do
    _ = parse_signature(v)
    acc <> <<byte_size(v)>> <> v <> <<0>>
  end

  defp put(acc, :variant, {signature, value}) when is_binary(signature) do
    case parse_signature(signature) do
      [type] -> acc |> put(:signature, signature) |> put(type, value)
      _other -> raise ArgumentError, "a variant holds one complete type, got #{signature}"
    end
  end

  defp put(acc, {:array, type}, values) when is_list(values) or is_map(values) do
    acc = pad(acc, 4)
    length_at = byte_size(acc)
    acc = pad(acc <> <<0::32>>, alignment(type))
    start = byte_size(acc)
    acc = Enum.reduce(items(type, values), acc, &put(&2, type, &1))
    length = byte_size(acc) - start
    if length > @max_array, do: raise(ArgumentError, "array over 64 MiB")
    <<head::binary-size(^length_at), _::32, rest::binary>> = acc
    head <> <<length::little-32>> <> rest
  end

  defp put(acc, {:struct, types}, tuple)
       when is_tuple(tuple) and tuple_size(tuple) == length(types) do
    types
    |> Enum.zip(Tuple.to_list(tuple))
    |> Enum.reduce(pad(acc, 8), fn {type, value}, acc -> put(acc, type, value) end)
  end

  defp put(acc, {:dict_entry, key_type, value_type}, {key, value}),
    do: acc |> pad(8) |> put(key_type, key) |> put(value_type, value)

  defp put(_acc, type, value),
    do: raise(ArgumentError, "#{inspect(value)} is not a D-Bus #{inspect(type)}")

  # Pairs go out in key order, so the same map is always the same bytes.
  defp items({:dict_entry, _, _}, %{} = map), do: Enum.sort(map)
  defp items(_type, list) when is_list(list), do: list

  defp items(type, value),
    do: raise(ArgumentError, "#{inspect(value)} is not an #{inspect(type)} list")

  defp text!(v) do
    if not String.valid?(v) or String.contains?(v, <<0>>),
      do: raise(ArgumentError, "D-Bus strings are UTF-8 without NUL bytes")
  end

  defp pad(acc, n) do
    case rem(byte_size(acc), n) do
      0 -> acc
      r -> acc <> :binary.copy(<<0>>, n - r)
    end
  end

  @doc "How many bytes a value of `type` aligns to."
  @spec alignment(type()) :: 1 | 2 | 4 | 8
  def alignment(type) when type in [:byte, :signature, :variant], do: 1
  def alignment(type) when type in [:int16, :uint16], do: 2

  def alignment(type) when type in [:boolean, :int32, :uint32, :string, :object_path],
    do: 4

  def alignment({:array, _}), do: 4
  def alignment(_eight), do: 8

  @doc """
  Reads values of `types` from `binary`, starting at byte `pos`. Returns the
  values and where reading stopped. Raises on bytes that don't hold them.
  """
  @spec decode([type()], binary(), non_neg_integer(), endian()) ::
          {[term()], non_neg_integer()}
  def decode(types, binary, pos, endian) when endian in [:little, :big],
    do: Enum.map_reduce(types, pos, &get(binary, &2, &1, endian))

  defp get(bin, pos, :byte, _endian) do
    <<_::binary-size(^pos), v, _::binary>> = bin
    {v, pos + 1}
  end

  defp get(bin, pos, :boolean, endian) do
    case uint(bin, align(pos, 4), 32, endian) do
      {0, pos} -> {false, pos}
      {1, pos} -> {true, pos}
      {other, _pos} -> raise ArgumentError, "boolean #{other}"
    end
  end

  defp get(bin, pos, :int16, endian), do: int(bin, align(pos, 2), 16, endian)
  defp get(bin, pos, :uint16, endian), do: uint(bin, align(pos, 2), 16, endian)
  defp get(bin, pos, :int32, endian), do: int(bin, align(pos, 4), 32, endian)
  defp get(bin, pos, :uint32, endian), do: uint(bin, align(pos, 4), 32, endian)
  defp get(bin, pos, :int64, endian), do: int(bin, align(pos, 8), 64, endian)
  defp get(bin, pos, :uint64, endian), do: uint(bin, align(pos, 8), 64, endian)

  defp get(bin, pos, :double, endian) do
    pos = align(pos, 8)
    <<_::binary-size(^pos), raw::binary-size(8), _::binary>> = bin

    value =
      case endian do
        :little ->
          <<v::little-float-64>> = raw
          v

        :big ->
          <<v::big-float-64>> = raw
          v
      end

    {value, pos + 8}
  end

  defp get(bin, pos, type, endian) when type in [:string, :object_path] do
    {length, pos} = uint(bin, align(pos, 4), 32, endian)
    <<_::binary-size(^pos), v::binary-size(^length), 0, _::binary>> = bin
    {v, pos + length + 1}
  end

  defp get(bin, pos, :signature, _endian) do
    <<_::binary-size(^pos), length, v::binary-size(length), 0, _::binary>> = bin
    {v, pos + 1 + length + 1}
  end

  defp get(bin, pos, :variant, endian) do
    {signature, pos} = get(bin, pos, :signature, endian)

    case parse_signature(signature) do
      [type] ->
        {value, pos} = get(bin, pos, type, endian)
        {{signature, value}, pos}

      _other ->
        raise ArgumentError, "variant of #{inspect(signature)}"
    end
  end

  defp get(bin, pos, {:array, type}, endian) do
    {length, pos} = uint(bin, align(pos, 4), 32, endian)
    if length > @max_array, do: raise(ArgumentError, "array over 64 MiB")
    start = align(pos, alignment(type))
    items(bin, start, start + length, type, endian, [])
  end

  defp get(bin, pos, {:struct, types}, endian) do
    {values, pos} = decode(types, bin, align(pos, 8), endian)
    {List.to_tuple(values), pos}
  end

  defp get(bin, pos, {:dict_entry, key_type, value_type}, endian) do
    {[key, value], pos} = decode([key_type, value_type], bin, align(pos, 8), endian)
    {{key, value}, pos}
  end

  defp items(_bin, pos, stop, _type, _endian, acc) when pos == stop,
    do: {Enum.reverse(acc), pos}

  defp items(bin, pos, stop, type, endian, acc) when pos < stop do
    {value, next} = get(bin, pos, type, endian)
    # Padding before the next item lies inside the array.
    next_item = if next < stop, do: align(next, alignment(type)), else: next
    items(bin, next_item, stop, type, endian, [value | acc])
  end

  defp items(_bin, _pos, _stop, _type, _endian, _acc),
    do: raise(ArgumentError, "array items overrun its length")

  defp uint(bin, pos, size, :little) do
    <<_::binary-size(^pos), v::little-size(^size), _::binary>> = bin
    {v, pos + div(size, 8)}
  end

  defp uint(bin, pos, size, :big) do
    <<_::binary-size(^pos), v::big-size(^size), _::binary>> = bin
    {v, pos + div(size, 8)}
  end

  defp int(bin, pos, size, :little) do
    <<_::binary-size(^pos), v::little-signed-size(^size), _::binary>> = bin
    {v, pos + div(size, 8)}
  end

  defp int(bin, pos, size, :big) do
    <<_::binary-size(^pos), v::big-signed-size(^size), _::binary>> = bin
    {v, pos + div(size, 8)}
  end

  @doc false
  def align(pos, n) do
    case rem(pos, n) do
      0 -> pos
      r -> pos + n - r
    end
  end
end
