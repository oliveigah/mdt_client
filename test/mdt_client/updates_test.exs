defmodule MDTClient.UpdatesTest do
  use ExUnit.Case, async: true

  alias MDTClient.Updates

  @base "https://github.com/oliveigah/mdt_client/releases/download/0.6.0/"

  test "startup leaves the updater idle without scheduling a check" do
    assert {:ok, %{status: :idle, task: nil}} = Updates.init(nil)
    {:messages, messages} = Process.info(self(), :messages)
    refute :check in messages
  end

  test "selects the matching newer package and checksum file" do
    release = release("0.6.0")

    assert {:ok, selected} = Updates.select_release(release, "0.5.0", :rpm)
    assert selected.version == "0.6.0"
    assert selected.name == "MDT_0.6.0.rpm"
    assert selected.package_url == @base <> "MDT_0.6.0.rpm"
  end

  test "ignores current and older versions and incomplete releases" do
    assert :none = Updates.select_release(release("0.6.0"), "0.6.0", :deb)
    assert :none = Updates.select_release(release("0.6.0"), "0.7.0", :deb)

    incomplete =
      Map.update!(release("0.6.0"), "assets", fn assets ->
        Enum.reject(assets, fn asset -> asset["name"] == "SHA256SUMS" end)
      end)

    assert :none = Updates.select_release(incomplete, "0.5.0", :deb)
  end

  test "rejects a package URL outside the repository" do
    release = release("0.6.0")

    assets =
      Enum.map(release["assets"], fn asset ->
        if asset["name"] == "MDT_0.6.0.deb" do
          %{asset | "browser_download_url" => "https://example.com/MDT_0.6.0.deb"}
        else
          asset
        end
      end)

    assert :none = Updates.select_release(%{release | "assets" => assets}, "0.5.0", :deb)
  end

  test "accepts only the exact checksum entry" do
    wanted = String.duplicate("a", 64)
    other = String.duplicate("b", 64)
    sums = "#{other}  ./MDT_0.6.0.rpm\n#{wanted}  ./MDT_0.6.0.deb\n"

    assert {:ok, ^wanted} = Updates.checksum(sums, "MDT_0.6.0.deb")
    assert :error = Updates.checksum(sums, "MDT_0.7.0.deb")
    assert :error = Updates.checksum("not-a-hash  MDT_0.6.0.deb", "MDT_0.6.0.deb")
  end

  defp release(tag) do
    %{
      "tag_name" => tag,
      "assets" =>
        Enum.map(["MDT_0.6.0.deb", "MDT_0.6.0.rpm", "SHA256SUMS"], fn name ->
          %{"name" => name, "browser_download_url" => @base <> name}
        end)
    }
  end
end
