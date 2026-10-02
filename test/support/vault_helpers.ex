defmodule MDTClient.VaultHelpers do
  @moduledoc """
  Sets up an unlocked identity for tests that need somewhere to persist.
  """

  alias MDTClient.Accounts
  alias MDTClient.Vault.Store

  @doc "Unlocks a unique identity and cleans up only its stores and directory on exit."
  def unlocked_identity(username \\ "tester", password \\ "correct horse") do
    username = unique_username(username)
    directory = Accounts.dir(username)

    ExUnit.Callbacks.on_exit(fn ->
      Store.close(username)
      File.rm_rf!(directory)
    end)

    {:ok, profile, key} = Accounts.sign_in(username, password)
    :ok = Store.open(profile.username, key)

    %{username: profile.username, password: password, key: key}
  end

  @doc "Unlocks an extra identity alongside the current one."
  def also_unlock(username, password \\ "correct horse") do
    unlocked_identity(username, password).username
  end

  @doc "Returns a username that cannot collide with another test's identity."
  def unique_username(prefix) do
    prefix <> "-#{System.unique_integer([:positive, :monotonic])}"
  end

  @doc "Removes all application data. Only use in synchronous tests that need global state reset."
  def reset_data_dir!, do: File.rm_rf!(Accounts.root())
end
