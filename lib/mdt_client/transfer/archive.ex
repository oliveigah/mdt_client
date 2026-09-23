defmodule MDTClient.Transfer.Archive do
  @moduledoc """
  The export file format.

      <<"MDTEXPORT", version::8, header_size::32, header::binary, payload::binary>>

  The header is JSON holding what is needed to derive the key again from a
  password — the KDF parameters and a salt, as in `vault.json` — plus a
  verifier: a constant sealed under that key, which tells a wrong key apart
  from a damaged file. The payload is the contents, compressed and sealed
  with `MDTClient.Vault`.

  Nothing here holds a key. Sealing goes through a function, so an export can
  be sealed by `MDTClient.Vault.Keyring` under the identity's own key; opening
  takes either that same kind of function or the password, whose key is
  derived again from the header.
  """

  alias MDTClient.Vault

  @magic "MDTEXPORT"
  @version 1
  @verifier "mdt:export:verifier:v1"
  @algorithm "pbkdf2-hmac-sha512"
  @key_bytes 32
  # The header is read before anything is authenticated, so a file could ask
  # for enough iterations to hang the app. This is ~15x the current setting.
  @max_iterations 10_000_000

  @typedoc "Seals a term under some key, as `MDTClient.Vault.seal/2` does."
  @type seal :: (term() -> binary())

  @typedoc """
  How to open an export: with the password it was sealed under, or with a
  function that opens blobs sealed under a key already at hand.
  """
  @type opener :: {:password, String.t()} | {:open, (binary() -> {:ok, term()} | :error)}

  @type error :: :not_an_export | :unsupported_version | :bad_password | :damaged

  @doc """
  Seals `contents` with `seal`.

  `kdf` goes into the header as is, and must say how the sealing key derives
  from its password: `"algorithm"`, `"iterations"`, `"length"` and a base64
  `"salt"`, as `MDTClient.Vault.Keyring.kdf/1` returns them.
  """
  @spec encode(term(), map(), seal()) :: binary()
  def encode(contents, %{"salt" => _salt} = kdf, seal) when is_function(seal, 1) do
    header = Jason.encode!(%{"kdf" => kdf, "verifier" => Base.encode64(seal.(@verifier))})

    # Compressed before sealing, since ciphertext does not compress. Response
    # bodies are mostly text, so this is where most of an export's size goes.
    payload = seal.(:erlang.term_to_binary(contents, compressed: 6))

    <<@magic, @version, byte_size(header)::32, header::binary, payload::binary>>
  end

  @doc """
  Opens an export.

  Only a holder of the key could have produced a payload that authenticates,
  and the payload is decoded only once it has.
  """
  @spec decode(binary(), opener()) :: {:ok, term()} | {:error, error()}
  def decode(<<@magic, @version, size::32, header::binary-size(size), payload::binary>>, opener) do
    with {:ok, salt, params, verifier} <- parse_header(header),
         open = opener(opener, salt, params),
         {:verifier, {:ok, @verifier}} <- {:verifier, open.(verifier)},
         {:ok, compressed} <- open.(payload),
         {:ok, contents} <- decompress(compressed) do
      {:ok, contents}
    else
      {:verifier, _mismatch} -> {:error, :bad_password}
      _damaged -> {:error, :damaged}
    end
  end

  def decode(<<@magic, _newer, _rest::binary>>, _opener), do: {:error, :unsupported_version}
  def decode(_binary, _opener), do: {:error, :not_an_export}

  defp opener({:password, password}, salt, params) when is_binary(password) do
    key = Vault.derive(password, salt, params)
    &Vault.open(key, &1)
  end

  defp opener({:open, open}, _salt, _params) when is_function(open, 1), do: open

  defp parse_header(header) do
    with {:ok, %{"kdf" => kdf, "verifier" => verifier}} <- Jason.decode(header),
         %{"algorithm" => @algorithm, "length" => @key_bytes, "iterations" => iterations} <- kdf,
         true <- is_integer(iterations) and iterations in 1..@max_iterations,
         {:ok, salt} <- decode64(kdf["salt"]),
         {:ok, verifier} <- decode64(verifier) do
      {:ok, salt, kdf, verifier}
    else
      _invalid -> :error
    end
  end

  defp decode64(value) when is_binary(value), do: Base.decode64(value)
  defp decode64(_value), do: :error

  # Plain `binary_to_term/1` for the reason given in `MDTClient.Vault.open/2`.
  # Unlike a vault file an export can come from elsewhere, but only from
  # someone who held its key; `docs/transfer.md` covers what that trusts.
  defp decompress(compressed) when is_binary(compressed) do
    {:ok, :erlang.binary_to_term(compressed)}
  rescue
    ArgumentError -> :error
  end

  defp decompress(_other), do: :error
end
