defmodule MDTClient.Vault.KeyringTest do
  use ExUnit.Case, async: true

  import MDTClient.VaultHelpers

  alias MDTClient.Accounts
  alias MDTClient.Vault
  alias MDTClient.Vault.Keyring
  alias MDTClient.Vault.Store

  setup do
    unlocked_identity()
  end

  test "seals under the identity's own key", %{username: username, key: key} do
    blob = Keyring.seal(username, "secret")

    assert Vault.open(key, blob) == {:ok, "secret"}
    assert Keyring.open(username, Vault.seal(key, "secret")) == {:ok, "secret"}
  end

  test "knows how that key derives from the password", %{
    username: username,
    password: password,
    key: key
  } do
    kdf = Keyring.kdf(username)

    assert {:ok, ^kdf} = Accounts.kdf(username)
    assert Vault.derive(password, Base.decode64!(kdf["salt"]), kdf) == key
  end

  test "another identity's keyring cannot open it", %{username: username} do
    blob = Keyring.seal(username, "secret")
    other = also_unlock("someone-else")

    assert Keyring.open(other, blob) == :error
  end

  test "goes down with the vault", %{username: username} do
    :ok = Store.close(username)

    catch_exit(Keyring.seal(username, "secret"))
  end
end
