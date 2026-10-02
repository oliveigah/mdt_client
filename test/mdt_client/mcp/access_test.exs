defmodule MDTClient.MCP.AccessTest do
  use ExUnit.Case, async: true

  import MDTClient.VaultHelpers
  import ExUnit.CaptureLog
  alias MDTClient.Accounts
  alias MDTClient.MCP.Access
  alias MDTClient.Vault
  alias MDTClient.Vault.Store

  setup do
    unlocked_identity()
  end

  test "tokens belong to one identity and rotation and revocation survive reopening", %{
    username: username,
    key: key
  } do
    other = also_unlock("other")
    {:ok, token} = Access.issue(username)
    {:ok, other_token} = Access.issue(other)
    assert {:ok, ^username} = Access.authorize(token)
    assert {:ok, ^other} = Access.authorize(other_token)
    assert Access.enabled?(username)
    assert Access.authorize("made up") == :error
    assert Access.authorize(nil) == :error

    {:ok, rotated} = Access.issue(username)
    refute token == rotated
    assert Access.authorize(token) == :error
    assert {:ok, ^username} = Access.authorize(rotated)
    :ok = Store.close(username)
    :ok = Store.open(username, key)
    assert Access.authorize(token) == :error
    assert {:ok, ^username} = Access.authorize(rotated)
    :ok = Access.revoke(username)
    :ok = Store.close(username)
    :ok = Store.open(username, key)
    refute Access.enabled?(username)
    assert Access.authorize(rotated) == :error
    assert {:ok, ^other} = Access.authorize(other_token)
  end

  test "locking pauses access and the saved token resumes in a fresh process", %{
    username: username,
    key: key
  } do
    {:ok, token} = Access.issue(username)
    owner = Store.whereis(Access, username)
    monitor = Process.monitor(owner)
    :ok = Store.close(username)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :shutdown}
    assert Access.authorize(token) == :error
    assert Access.issue(username) == {:error, :locked}
    assert Registry.lookup(MDTClient.MCP.Registry, :crypto.hash(:sha256, token)) == []
    :ok = Store.open(username, key)
    refute Store.whereis(Access, username) == owner
    assert {:ok, ^username} = Access.authorize(token)
    assert Access.enabled?(username)
  end

  test "only the token hash is saved, encrypted before generation returns", %{
    username: username,
    key: key
  } do
    {:ok, token} = Access.issue(username)
    blob = File.read!(Accounts.store_path(username, "mcp_access.bin"))
    refute blob =~ token
    assert Vault.open(key, blob) == {:ok, %{version: 1, hash: :crypto.hash(:sha256, token)}}
  end

  test "a failed rotation keeps the existing credential working", %{username: username, key: key} do
    {:ok, token} = Access.issue(username)
    partial = Accounts.store_path(username, "mcp_access.bin.part")
    File.mkdir!(partial)
    capture_log(fn -> assert Access.issue(username) == {:error, :storage} end)
    assert {:ok, ^username} = Access.authorize(token)
    :ok = Store.close(username)
    :ok = Store.open(username, key)
    assert {:ok, ^username} = Access.authorize(token)
  end

  test "a failed revocation leaves the token active and reports the failure", %{
    username: username
  } do
    {:ok, token} = Access.issue(username)
    path = Accounts.store_path(username, "mcp_access.bin")
    backup = path <> ".backup"
    File.rename!(path, backup)
    File.mkdir!(path)

    try do
      capture_log(fn -> assert Access.revoke(username) == {:error, :storage} end)
      assert {:ok, ^username} = Access.authorize(token)
      assert Access.enabled?(username)
    after
      File.rmdir!(path)
      File.rename!(backup, path)
    end
  end

  test "unreadable credentials grant no access and are kept for recovery", %{
    username: username,
    key: key
  } do
    {:ok, token} = Access.issue(username)
    :ok = Store.close(username)
    path = Accounts.store_path(username, "mcp_access.bin")
    File.write!(path, "damaged credential")
    capture_log(fn -> :ok = Store.open(username, key) end)
    assert Access.authorize(token) == :error
    refute Access.enabled?(username)
    assert File.read!(path) == "damaged credential"
  end
end
