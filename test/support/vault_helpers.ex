defmodule MDTClient.VaultHelpers do
  @moduledoc """
  Sets up an unlocked identity for tests that need somewhere to persist.
  """

  alias MDTClient.Accounts
  alias MDTClient.Vault.Store

  @doc "Wipes the data directory and unlocks a throwaway identity."
  def unlocked_identity(username \\ "tester", password \\ "correct horse") do
    reset_data_dir!()

    {:ok, profile, key} = Accounts.sign_in(username, password)
    :ok = Store.open(profile.username, key)

    ExUnit.Callbacks.on_exit(fn ->
      Store.close(profile.username)
      reset_data_dir!()
    end)

    %{username: profile.username, password: password, key: key}
  end

  @doc "Unlocks an extra identity alongside the current one."
  def also_unlock(username, password \\ "correct horse") do
    {:ok, profile, key} = Accounts.sign_in(username, password)
    :ok = Store.open(profile.username, key)
    ExUnit.Callbacks.on_exit(fn -> Store.close(profile.username) end)
    profile.username
  end

  @doc "Removes everything MDT has written."
  def reset_data_dir!, do: File.rm_rf!(Accounts.root())
end
