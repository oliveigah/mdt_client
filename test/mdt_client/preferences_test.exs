defmodule MDTClient.PreferencesTest do
  use ExUnit.Case, async: false

  alias MDTClient.Accounts
  alias MDTClient.Preferences

  setup do
    File.rm_rf!(Accounts.root())
    on_exit(fn -> File.rm_rf!(Accounts.root()) end)
  end

  test "defaults apply before anything is written" do
    assert Preferences.get("theme") == "system"
    assert Preferences.get("last_username") == nil
  end

  test "values round trip through the file" do
    :ok = Preferences.put("theme", "dark")
    :ok = Preferences.put("last_username", "oliveigah")

    assert Preferences.get("theme") == "dark"
    assert Preferences.get("last_username") == "oliveigah"
    assert Preferences.path() |> File.read!() |> Jason.decode!() |> Map.get("theme") == "dark"
  end

  test "a corrupt file falls back to defaults" do
    :ok = Preferences.put("theme", "dark")
    File.write!(Preferences.path(), "{not json")

    assert Preferences.get("theme") == "system"
  end

  test "preferences are stored in the clear, outside any identity" do
    :ok = Preferences.put("last_username", "oliveigah")

    assert File.read!(Preferences.path()) =~ "oliveigah"
    assert Path.dirname(Preferences.path()) == Accounts.root()
  end
end
