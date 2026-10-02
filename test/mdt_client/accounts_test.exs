defmodule MDTClient.AccountsTest do
  use ExUnit.Case, async: true

  alias MDTClient.Accounts
  alias MDTClient.Vault

  setup do
    suffix = System.unique_integer([:positive, :monotonic])
    usernames = %{username: "oliveigah#{suffix}", alice: "alice#{suffix}", bob: "bob#{suffix}"}

    on_exit(fn ->
      Enum.each(Map.values(usernames), fn username -> File.rm_rf!(Accounts.dir(username)) end)
    end)

    usernames
  end

  test "an unknown username creates a profile", %{username: username} do
    refute Accounts.exists?(username)

    assert {:ok, profile, key} = Accounts.sign_in(username, "correct horse")
    assert profile.username == username
    assert profile.initials == "O"
    assert byte_size(key) == 32
    assert Accounts.exists?(username)
  end

  test "a known username unlocks with the same key", %{username: username} do
    {:ok, _profile, created} = Accounts.sign_in(username, "correct horse")

    assert {:ok, _profile, ^created} = Accounts.sign_in(username, "correct horse")
  end

  test "the wrong password is rejected without touching the vault", %{username: username} do
    {:ok, _profile, key} = Accounts.sign_in(username, "correct horse")

    assert Accounts.sign_in(username, "wrong horse") == {:error, :bad_password}
    assert {:ok, _profile, ^key} = Accounts.sign_in(username, "correct horse")
  end

  test "usernames are matched case insensitively and trimmed", %{username: username} do
    {:ok, _profile, key} = Accounts.sign_in(String.capitalize(username), "correct horse")

    assert {:ok, profile, ^key} =
             Accounts.sign_in("  #{String.upcase(username)}  ", "correct horse")

    assert profile.username == username
  end

  test "two users sharing a password get different keys and directories", %{
    alice: alice,
    bob: bob
  } do
    {:ok, _profile, alice_key} = Accounts.sign_in(alice, "same password")
    {:ok, _profile, bob_key} = Accounts.sign_in(bob, "same password")

    refute alice_key == bob_key
    refute Accounts.dir(alice) == Accounts.dir(bob)
    assert Vault.open(bob_key, Vault.seal(alice_key, "alice's data")) == :error
  end

  test "the vault file holds nothing secret", %{username: username} do
    {:ok, _profile, _key} = Accounts.sign_in(username, "correct horse")

    body = File.read!(Path.join(Accounts.dir(username), "vault.json"))
    meta = Jason.decode!(body)

    refute String.contains?(body, "correct horse")
    assert meta["kdf"]["algorithm"] == "pbkdf2-hmac-sha512"
    assert meta["username"] == username
  end

  test "the directory name does not leak the username" do
    assert Accounts.id("oliveigah") =~ ~r/\A[0-9a-f]{64}\z/
    refute String.contains?(Accounts.dir("oliveigah"), "oliveigah")
  end

  test "blank credentials are refused" do
    assert Accounts.sign_in("   ", "correct horse") == {:error, :blank_username}
    assert Accounts.sign_in("oliveigah", "") == {:error, :blank_password}
  end

  test "a corrupt vault file is reported as such", %{username: username} do
    {:ok, _profile, _key} = Accounts.sign_in(username, "correct horse")
    File.write!(Path.join(Accounts.dir(username), "vault.json"), "{not json")

    assert Accounts.sign_in(username, "correct horse") == {:error, :unreadable_vault}
  end
end
