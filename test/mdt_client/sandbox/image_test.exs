defmodule MDTClient.Sandbox.ImageTest do
  use ExUnit.Case, async: true

  alias MDTClient.Sandbox.{Build, Image}

  doctest Image

  defp build(name, tag, minutes_ago) do
    %Build{
      ref: "#{name}:#{tag}",
      name: name,
      tag: tag,
      built_at: DateTime.add(~U[2026-11-12 12:00:00Z], -minutes_ago * 60, :second)
    }
  end

  test "tags count builds per day and per name" do
    builds = [build("box", "2026-11-12.1", 30), build("box", "2026-11-12.2", 10)]

    assert Image.next_tag("box", ~D[2026-11-12], builds) == "2026-11-12.3"
    assert Image.next_tag("box", ~D[2026-11-13], builds) == "2026-11-13.1"
    assert Image.next_tag("other", ~D[2026-11-12], builds) == "2026-11-12.1"
  end

  test "the newest three builds are kept, and the VM's even when older" do
    builds = for n <- 1..5, do: build("box", "2026-11-12.#{n}", 60 - n)

    {kept, removed} = Image.keep(builds, [])
    assert Enum.map(kept, & &1.tag) == ["2026-11-12.5", "2026-11-12.4", "2026-11-12.3"]
    assert Enum.map(removed, & &1.tag) == ["2026-11-12.2", "2026-11-12.1"]

    {kept, removed} = Image.keep(builds, ["box:2026-11-12.1"])
    assert "2026-11-12.1" in Enum.map(kept, & &1.tag)
    assert Enum.map(removed, & &1.tag) == ["2026-11-12.2"]
  end

  test "image names follow OCI's rules" do
    assert Image.valid_name?("mdt_agent_sdb_image")
    assert Image.valid_name?("box-2.v1")
    refute Image.valid_name?("Box")
    refute Image.valid_name?("box_")
    refute Image.valid_name?("box:tag")
    refute Image.valid_name?("")
  end

  test "MDT's layer only points at /mnt/mdt and /cache" do
    layer = Image.mdt_layer()
    assert layer =~ "/mnt/mdt/ca-bundle.pem"
    assert layer =~ "BASH_ENV=/mnt/mdt/profile.sh"
    assert layer =~ "MISE_DATA_DIR=/cache/mise"
    refute layer =~ "COPY"
  end

  test "the build reads what podman left without running the image" do
    dir = Path.join(System.tmp_dir!(), "image-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    File.write!(Path.join(dir, "versions.txt"), "erlang 29.1.2\n")
    File.write!(Path.join(dir, "size"), "4510000000\n")

    build =
      Image.read_build(dir, %{
        name: "box",
        tag: "2026-11-12.1",
        containerfile: "FROM x",
        built_at: ~U[2026-11-12 12:00:00Z]
      })

    assert build.ref == "box:2026-11-12.1"
    assert build.versions =~ "erlang"
    assert build.size == 4_510_000_000
    script = Image.build_script(dir, build.ref)
    assert script =~ "--format docker"
    # Loaded by MDT's msb, which Msb.env/0 names; never one on the PATH.
    assert script =~ ~s("$MSB_PATH" load --input)
  end
end
