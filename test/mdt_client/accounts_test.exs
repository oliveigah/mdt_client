defmodule MDTClient.AccountsTest do
  use ExUnit.Case, async: false

  alias MDTClient.Accounts
  alias MDTClient.Vault

  setup do
    File.rm_rf!(Accounts.root())
    on_exit(fn -> File.rm_rf!(Accounts.root()) end)
  end

  test "an unknown username creates a profile" do
    refute Accounts.exists?("oliveigah")

    assert {:ok, profile, key} = Accounts.sign_in("oliveigah", "correct horse")
    assert profile.username == "oliveigah"
    assert profile.initials == "O"
    assert byte_size(key) == 32
    assert Accounts.exists?("oliveigah")
  end

  test "a known username unlocks with the same key" do
    {:ok, _profile, created} = Accounts.sign_in("oliveigah", "correct horse")

    assert {:ok, _profile, ^created} = Accounts.sign_in("oliveigah", "correct horse")
  end

  test "the wrong password is rejected without touching the vault" do
    {:ok, _profile, key} = Accounts.sign_in("oliveigah", "correct horse")

    assert Accounts.sign_in("oliveigah", "wrong horse") == {:error, :bad_password}
    assert {:ok, _profile, ^key} = Accounts.sign_in("oliveigah", "correct horse")
  end

  test "usernames are matched case insensitively and trimmed" do
    {:ok, _profile, key} = Accounts.sign_in("Oliveigah", "correct horse")

    assert {:ok, profile, ^key} = Accounts.sign_in("  oliveIGAH  ", "correct horse")
    assert profile.username == "oliveigah"
  end

  test "two users sharing a password get different keys and directories" do
    {:ok, _profile, alice} = Accounts.sign_in("alice", "same password")
    {:ok, _profile, bob} = Accounts.sign_in("bob", "same password")

    refute alice == bob
    refute Accounts.dir("alice") == Accounts.dir("bob")
    assert Vault.open(bob, Vault.seal(alice, "alice's data")) == :error
  end

  test "the vault file holds nothing secret" do
    {:ok, _profile, _key} = Accounts.sign_in("oliveigah", "correct horse")

    body = File.read!(Path.join(Accounts.dir("oliveigah"), "vault.json"))
    meta = Jason.decode!(body)

    refute String.contains?(body, "correct horse")
    assert meta["kdf"]["algorithm"] == "pbkdf2-hmac-sha512"
    assert meta["username"] == "oliveigah"
  end

  test "the directory name does not leak the username" do
    assert Accounts.id("oliveigah") =~ ~r/\A[0-9a-f]{64}\z/
    refute String.contains?(Accounts.dir("oliveigah"), "oliveigah")
  end

  test "blank credentials are refused" do
    assert Accounts.sign_in("   ", "correct horse") == {:error, :blank_username}
    assert Accounts.sign_in("oliveigah", "") == {:error, :blank_password}
  end

  test "a corrupt vault file is reported as such" do
    {:ok, _profile, _key} = Accounts.sign_in("oliveigah", "correct horse")
    File.write!(Path.join(Accounts.dir("oliveigah"), "vault.json"), "{not json")

    assert Accounts.sign_in("oliveigah", "correct horse") == {:error, :unreadable_vault}
  end
end
