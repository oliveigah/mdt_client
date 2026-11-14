defmodule MDTClient.Sandbox.SavingTest do
  @moduledoc """
  What the sandbox writes to disk without a clean stop to write it, as
  when `cargo tauri dev` restarts MDT.
  """
  use ExUnit.Case, async: true

  alias MDTClient.{Accounts, Sandbox}
  alias MDTClient.Sandbox.Server
  alias MDTClient.Sandbox.Server.State
  alias MDTClient.Vault.Store

  setup do
    identity = MDTClient.VaultHelpers.unlocked_identity("saving")
    base = Path.join(System.tmp_dir!(), "saving-#{System.unique_integer([:positive])}")
    for name <- ~w(one two), do: File.mkdir_p!(Path.join(base, name))
    on_exit(fn -> File.rm_rf!(base) end)
    Map.merge(identity, %{base: base, pid: Store.whereis(Server, identity.username)})
  end

  defp shares_on_disk(%{username: username, key: key}) do
    saved = State.restore(Accounts.store_path(username, "sandbox.bin"), key, username)
    Enum.map(saved.settings.shares, & &1.path)
  end

  # As a reload of the server's code in development leaves it: gen_server
  # skipped the :flush, and the timer that sent it is gone.
  defp lose_save(pid) do
    :sys.replace_state(pid, fn state ->
      if state.flush, do: Process.cancel_timer(state.flush)
      state
    end)
  end

  # The server's next :flush, once handled.
  defp await_save(pid) do
    :erlang.trace(pid, true, [:receive])
    assert_receive {:trace, ^pid, :receive, :flush}, 2_000
    :erlang.trace(pid, false, [:receive])
    _ = :sys.get_state(pid)
  end

  test "a change whose save got lost is saved with the next one", context do
    %{username: username, base: base, pid: pid} = context
    one = Path.join(base, "one")
    two = Path.join(base, "two")

    {:ok, _} = Sandbox.add_share(username, one, :ro)
    lose_save(pid)
    {:ok, _} = Sandbox.add_share(username, two, :ro)
    await_save(pid)

    assert Enum.sort(shares_on_disk(context)) == [one, two]
  end

  test "with no change after it, the sweep saves it", context do
    %{username: username, base: base, pid: pid} = context
    one = Path.join(base, "one")

    {:ok, _} = Sandbox.add_share(username, one, :ro)
    lose_save(pid)
    send(pid, :sweep)
    await_save(pid)

    assert shares_on_disk(context) == [one]
  end
end
