defmodule MDTClient.Vault do
  @moduledoc """
  Password derived encryption for everything MDT keeps on disk.

  The password *is* the key: `derive/2` stretches it with PBKDF2 and `seal/2`
  encrypts a term under the result. There is no wrapped data key, so changing a
  password means re-encrypting the data it protects.

  Every primitive comes from `:crypto`; nothing here is hand rolled.
  """

  @version 1
  @iterations 600_000
  @key_bytes 32
  @salt_bytes 16
  @nonce_bytes 12
  @tag_bytes 16

  @type key :: binary()

  @doc "The KDF parameters written into a new vault file."
  @spec kdf_params() :: map()
  def kdf_params do
    %{"algorithm" => "pbkdf2-hmac-sha512", "iterations" => @iterations, "length" => @key_bytes}
  end

  @doc "A fresh random salt."
  @spec salt() :: binary()
  def salt, do: :crypto.strong_rand_bytes(@salt_bytes)

  @doc """
  Stretches a password into an encryption key.

  Roughly 150ms by design: that cost is the whole defence against someone
  brute forcing a stolen vault offline.
  """
  @spec derive(String.t(), binary()) :: key()
  def derive(password, salt) when is_binary(password) and is_binary(salt) do
    :crypto.pbkdf2_hmac(:sha512, password, salt, @iterations, @key_bytes)
  end

  @doc "Same as `derive/2`, honouring the parameters stored in a vault file."
  @spec derive(String.t(), binary(), map()) :: key()
  def derive(password, salt, %{} = params) do
    :crypto.pbkdf2_hmac(
      :sha512,
      password,
      salt,
      Map.get(params, "iterations", @iterations),
      Map.get(params, "length", @key_bytes)
    )
  end

  @doc """
  Encrypts a term under `key`.

  The nonce is random per call and never reused: repeating one under the same
  key would leak the plaintexts and allow forgery.
  """
  @spec seal(key(), term()) :: binary()
  def seal(key, term) do
    nonce = :crypto.strong_rand_bytes(@nonce_bytes)
    plain = :erlang.term_to_binary(term)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, plain, "", true)

    <<@version, nonce::binary, tag::binary, ciphertext::binary>>
  end

  @doc """
  Decrypts a blob produced by `seal/2`.

  Returns `:error` for the wrong key, a tampered blob, or one this version
  cannot read. The tag is checked before anything is deserialised.
  """
  @spec open(key(), binary()) :: {:ok, term()} | :error
  def open(
        key,
        <<@version, nonce::binary-size(@nonce_bytes), tag::binary-size(@tag_bytes),
          ciphertext::binary>>
      ) do
    case :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, ciphertext, "", tag, false) do
      :error -> :error
      plain -> safe_term(plain)
    end
  end

  def open(_key, _blob), do: :error

  # Authenticated by the tag above, but `:safe` still keeps a surprising blob
  # from minting atoms.
  defp safe_term(plain) do
    {:ok, :erlang.binary_to_term(plain, [:safe])}
  rescue
    ArgumentError -> :error
  end
end
