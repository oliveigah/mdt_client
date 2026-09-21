defmodule MDTClient.VaultTest do
  use ExUnit.Case, async: true

  alias MDTClient.Vault

  setup do
    salt = Vault.salt()
    %{salt: salt, key: Vault.derive("correct horse", salt)}
  end

  test "seals and opens a term", %{key: key} do
    term = %{history: [{1, "GET", ~U[2026-09-21 10:00:00Z]}]}

    assert {:ok, ^term} = key |> Vault.seal(term) |> then(&Vault.open(key, &1))
  end

  test "a different password cannot open the blob", %{key: key, salt: salt} do
    blob = Vault.seal(key, "secret")

    assert Vault.open(Vault.derive("wrong horse", salt), blob) == :error
  end

  test "the same password with a different salt derives a different key", %{key: key} do
    other = Vault.derive("correct horse", Vault.salt())

    refute other == key
    assert Vault.open(other, Vault.seal(key, "secret")) == :error
  end

  test "a tampered blob is rejected", %{key: key} do
    <<head::binary-20, byte, rest::binary>> = Vault.seal(key, "secret")

    assert Vault.open(key, <<head::binary, Bitwise.bxor(byte, 1), rest::binary>>) == :error
  end

  test "a truncated or foreign blob is rejected", %{key: key} do
    assert Vault.open(key, "") == :error
    assert Vault.open(key, "not a vault blob") == :error
    assert Vault.open(key, <<99, 0::96, 0::128>>) == :error
  end

  test "the ciphertext carries no plaintext", %{key: key} do
    blob = Vault.seal(key, %{url: "https://api.example.test/health", note: "Health check"})

    refute String.contains?(blob, "api.example.test")
    refute String.contains?(blob, "Health check")
  end

  test "every seal uses a fresh nonce", %{key: key} do
    refute Vault.seal(key, "same") == Vault.seal(key, "same")
  end

  test "derive honours stored parameters", %{salt: salt} do
    params = %{"iterations" => 1_000, "length" => 32}

    assert byte_size(Vault.derive("pw", salt, params)) == 32
    refute Vault.derive("pw", salt, params) == Vault.derive("pw", salt)
  end
end
