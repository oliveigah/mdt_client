defmodule MDTClient.Sandbox.DestinationsTest do
  use ExUnit.Case, async: true

  alias MDTClient.Sandbox.Destinations

  test "classifies refused, private and public addresses" do
    own = [{192, 168, 15, 97}]

    assert Destinations.classify({127, 0, 0, 1}, own) == :refused
    assert Destinations.classify({169, 254, 169, 254}, own) == :refused
    assert Destinations.classify({0, 0, 0, 0, 0, 0, 0, 1}, own) == :refused
    assert Destinations.classify({192, 168, 15, 97}, own) == :refused
    assert Destinations.classify({0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 1}, own) == :refused
    assert Destinations.classify({192, 168, 15, 1}, own) == :private
    assert Destinations.classify({10, 20, 4, 12}, own) == :private
    assert Destinations.classify({100, 64, 1, 1}, own) == :private
    assert Destinations.classify({0xFD00, 0, 0, 0, 0, 0, 0, 5}, own) == :private
    assert Destinations.classify({140, 82, 112, 3}, own) == :public
  end

  test "parses ranges, addresses and names with ports" do
    assert {:ok, %{match: {:cidr, {10, 20, 0, 0}, 16}, ports: [443, 5432]}} =
             Destinations.parse("10.20.0.0/16:443,5432 # office")

    assert {:ok, %{match: {:cidr, {127, 0, 0, 1}, 32}, ports: [5433]}} =
             Destinations.parse("127.0.0.1:5433")

    assert {:ok, %{match: {:host, "git.corp.internal"}, ports: :any}} =
             Destinations.parse("git.corp.internal")

    assert {:ok, %{match: {:cidr, {0xFD00, 0, 0, 0, 0, 0, 0, 5}, 128}, ports: [22]}} =
             Destinations.parse("[fd00::5]:22")

    assert {:error, _} = Destinations.parse("10.20.0.0/40")
    assert {:error, _} = Destinations.parse("host:99999")
    assert {:error, _} = Destinations.parse("not a host!")
  end

  test "matches addresses, ranges, resolved names and ports" do
    {:ok, range} = Destinations.parse("10.20.0.0/16:5432")
    assert Destinations.matches?(range, {10, 20, 4, 12}, 5432)
    refute Destinations.matches?(range, {10, 20, 4, 12}, 22)
    refute Destinations.matches?(range, {10, 21, 0, 1}, 5432)

    {:ok, name} = Destinations.parse("db.internal")
    resolve = fn "db.internal" -> [{10, 9, 8, 7}] end
    assert Destinations.matches?(name, {10, 9, 8, 7}, 5432, resolve)
    refute Destinations.matches?(name, {10, 9, 8, 6}, 5432, resolve)

    {:ok, exact} = Destinations.parse("127.0.0.1:5433")
    assert Destinations.exact?(exact, {127, 0, 0, 1})
    refute Destinations.exact?(range, {10, 20, 4, 12})
  end
end
