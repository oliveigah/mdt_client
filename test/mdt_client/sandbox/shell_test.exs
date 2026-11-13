defmodule MDTClient.Sandbox.ShellTest do
  use ExUnit.Case, async: true

  alias MDTClient.Sandbox.Msb

  setup do
    dir = Path.join(System.tmp_dir!(), "sandbox-shell-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "home"))
    on_exit(fn -> File.rm_rf!(dir) end)

    for name <- ["profile", "bashrc"] do
      script =
        File.read!(Path.join([:code.priv_dir(:mdt_client), "sandbox", "mdt-#{name}.sh"]))
        |> String.replace("/mnt/mdt", dir)
        |> String.replace("/cache", dir <> "/cache")
        |> String.replace("/usr/local/share", dir <> "/usr/local/share")

      File.write!(Path.join(dir, "#{name}.sh"), script)
    end

    File.write!(Path.join(dir, "env.sh"), "export MDT_TEST_GRANT=placeholder\n")

    for {path, command} <- [
          {"cache/mise/shims", "runtime-tool"},
          {"usr/local/share/mise/shims", "baked-tool"},
          {"usr/local/share/cargo/bin", "cargo-tool"},
          {"home/.local/bin", "home-tool"}
        ] do
      bin = Path.join(dir, path)
      File.mkdir_p!(bin)
      File.write!(Path.join(bin, command), "#!/bin/sh\necho #{command}\n")
      File.chmod!(Path.join(bin, command), 0o755)
    end

    env = [
      {"HOME", Path.join(dir, "home")},
      {"PATH", "/usr/bin:/bin"},
      {"BASH_ENV", Path.join(dir, "profile.sh")},
      {"MDT_TEST_PROFILE", Path.join(dir, "profile.sh")},
      {"ZED_FILE_WATCHER_MODE", "native"},
      {"ZED_FILE_WATCHER_POLL_MS", "30000"},
      {"MDT_TEST_GRANT", nil}
    ]

    %{dir: dir, env: env}
  end

  test "SSH uses Bash independently of the image's CMD or passwd entry" do
    args =
      Msb.create_args(%{
        name: "test",
        image: "box:1",
        shell: "/bin/bash",
        cpus: 4,
        memory_gib: 8,
        disk_gib: 64,
        write_budget_gib: 32,
        proxy_port: 18080,
        mounts: [{"/host/project", "/project", :ro}, {"/host/cache", "/cache", :rw}],
        env: [{"GH_TOKEN", "placeholder"}]
      })

    assert ["/bin/bash" | _] = args |> Enum.drop_while(&(&1 != "--shell")) |> tl()
    assert ["64G" | _] = args |> Enum.drop_while(&(&1 != "--root-disk")) |> tl()

    # Read-only folders take no writes; read-write ones get the write budget
    # instead of microsandbox's 4 GiB.
    volumes = for {"--volume", volume} <- Enum.zip(args, tl(args)), do: volume
    assert volumes == ["/host/project:/project:ro", "/host/cache:/cache:quota=32G"]

    assert ["GH_TOKEN=placeholder" | _] = args |> Enum.drop_while(&(&1 != "--env")) |> tl()
  end

  test "commands and login probes find baked, cached and Home tools with empty Home", %{env: env} do
    command = "runtime-tool; baked-tool; cargo-tool; home-tool; echo grant=$MDT_TEST_GRANT"

    for flag <- ["-c", "-lc"] do
      assert {output, 0} = System.cmd("bash", [flag, command], env: env, stderr_to_stdout: true)
      assert output == "runtime-tool\nbaked-tool\ncargo-tool\nhome-tool\ngrant=placeholder\n"
    end
  end

  test "loading the profile repeatedly preserves PATH and reads updated grants", %{
    dir: dir,
    env: env
  } do
    command = ~S"""
    before=$PATH
    . "$MDT_TEST_PROFILE"
    test "$before" = "$PATH" || exit 1
    test "$MDT_TEST_GRANT" = placeholder || exit 2
    printf 'export MDT_TEST_GRANT=updated\n' > "$(dirname "$MDT_TEST_PROFILE")/env.sh"
    . "$MDT_TEST_PROFILE"
    test "$MDT_TEST_GRANT" = updated || exit 3
    """

    assert {"", 0} = System.cmd("sh", ["-c", ". \"#{dir}/profile.sh\"; " <> command], env: env)
  end

  test "commands and SSH login probes poll shared files instead of relying on inotify", %{
    env: env
  } do
    command = ~S"""
    test "$ZED_FILE_WATCHER_MODE" = poll || exit 1
    test "$ZED_FILE_WATCHER_POLL_MS" = 5000 || exit 2
    """

    for flag <- ["-c", "-lc"] do
      assert {"", 0} = System.cmd("bash", [flag, command], env: env, stderr_to_stdout: true)
    end
  end

  test "interactive Bash has tools, history and a prompt without dotfiles", %{dir: dir, env: env} do
    command = ~S"""
    runtime-tool && baked-tool && home-tool || exit 1
    shopt -q histappend checkwinsize || exit 2
    test "$HISTSIZE" = 10000 || exit 3
    test "$MDT_TEST_GRANT" = placeholder || exit 4
    case "$PS1" in *mdt*) ;; *) exit 5 ;; esac
    """

    assert {output, 0} =
             System.cmd("bash", ["--rcfile", Path.join(dir, "bashrc.sh"), "-ic", command],
               env: env,
               stderr_to_stdout: true
             )

    assert output =~ "runtime-tool\nbaked-tool\nhome-tool\n"
  end
end
