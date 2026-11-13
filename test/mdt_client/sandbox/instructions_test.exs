defmodule MDTClient.Sandbox.InstructionsTest do
  use ExUnit.Case, async: true

  alias MDTClient.Sandbox.{Allowance, Grant, Instructions}

  doctest Instructions

  test "the block is replaced where it is, and what's around it stays" do
    once = Instructions.put_block("my own notes\n", "first")
    twice = Instructions.put_block(once, "second")

    assert twice =~ "second"
    refute twice =~ "first"
    assert String.ends_with?(twice, "my own notes\n")
    assert Instructions.put_block(twice, "second") == twice
    assert Instructions.put_block("", "only") =~ ~r/^<!-- mdt:begin.*only\n<!-- mdt:end -->\n$/s
  end

  # The VM puts the block in its own files, after every boot, with the script
  # MDT runs in it. Here the script runs on this machine, pointed at folders
  # of the test's.
  describe "the boot script" do
    setup do
      base = Path.join(System.tmp_dir!(), "boot-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(base) end)
      inbox = Path.join(base, "inbox")
      home = Path.join(base, "home")
      File.mkdir_p!(inbox)
      File.mkdir_p!(home)
      File.write!(Path.join(inbox, "agents-block.md"), Instructions.block())

      etc = Path.join(base, "etc")
      File.mkdir_p!(etc)

      boot = fn args ->
        # POSIX sh, as in an image without bash.
        System.cmd(
          "sh",
          [Path.join([:code.priv_dir(:mdt_client), "sandbox", "mdt-boot"]) | args],
          env: [{"MDT_INBOX", inbox}, {"HOME", home}, {"MDT_ETC", etc}],
          stderr_to_stdout: true
        )
      end

      %{inbox: inbox, home: home, etc: etc, boot: fn -> boot.([]) end, boot_as: boot}
    end

    test "writes which VM this is, and a line for every interactive login shell", %{
      inbox: inbox,
      etc: etc,
      boot_as: boot_as
    } do
      assert {"", 0} =
               boot_as.(["3f2a9c1e", "2026-11-13T20:29:32Z", "img:2026-11-13.4", "mdt-4790"])

      assert File.read!(Path.join(etc, "mdt-vm")) ==
               "id=3f2a9c1e\ncreated=2026-11-13T20:29:32Z\nimage=img:2026-11-13.4\nname=mdt-4790\n"

      # The line asks `mdt vm`: dim when this is MDT's VM, red when it isn't.
      fake = Path.join(inbox, "bin/mdt")
      File.mkdir_p!(Path.dirname(fake))
      profile = Path.join(etc, "profile.d/mdt-vm.sh")

      shell = fn mode, status ->
        File.write!(fake, "#!/bin/sh\necho \"answer for $1\"\nexit #{status}\n")
        File.chmod!(fake, 0o755)
        # An interactive bash with no terminal complains about job control on
        # stderr; only what the line prints counts.
        System.cmd("sh", [
          "-c",
          ~S(exec bash --norc "$0" -c '. "$1"' shell "$1" 2>/dev/null),
          mode,
          profile
        ])
      end

      assert {"\e[2manswer for vm\e[0m\n", 0} = shell.("-i", 0)
      assert {"\e[1;31manswer for vm\e[0m\n", 0} = shell.("-i", 3)
      # Agents' shells aren't interactive: they hear nothing.
      assert {"", 0} = shell.("+m", 3)
    end

    test "writes no record when MDT names no VM", %{etc: etc, boot: boot} do
      assert {"", 0} = boot.()
      refute File.exists?(Path.join(etc, "mdt-vm"))
      refute File.exists?(Path.join(etc, "profile.d/mdt-vm.sh"))
    end

    test "Claude Code and Codex both get the block in Home", %{home: home, boot: boot} do
      File.mkdir_p!(Path.join(home, ".codex"))
      File.write!(Path.join(home, ".codex/AGENTS.md"), "Prefer small commits.\n")

      assert {"", 0} = boot.()

      claude = File.read!(Path.join(home, ".claude/CLAUDE.md"))
      codex = File.read!(Path.join(home, ".codex/AGENTS.md"))
      assert claude == Instructions.block()
      assert codex == Instructions.block() <> "\nPrefer small commits.\n"
    end

    test "a later boot replaces the block and leaves the rest", %{
      inbox: inbox,
      home: home,
      boot: boot
    } do
      assert {"", 0} = boot.()
      file = Path.join(home, ".claude/CLAUDE.md")
      File.write!(file, File.read!(file) <> "\nmy own notes\n")

      File.write!(Path.join(inbox, "agents-block.md"), Instructions.put_block("", "changed"))
      assert {"", 0} = boot.()

      assert File.read!(file) == Instructions.put_block("", "changed") <> "\nmy own notes\n"
      # The script and `put_block/2` agree on where the block goes.
      assert File.read!(file) == Instructions.put_block(File.read!(file), "changed")
    end

    test "the memo tool is copied into the VM's memory folder, which gets a memory", %{
      inbox: inbox,
      home: home,
      boot: boot
    } do
      File.mkdir_p!(Path.join(inbox, "bin"))
      memo = Path.join(inbox, "bin/memo")
      File.write!(memo, "#!/bin/sh\nmkdir -p \"$MEMORY_DIR\" && : > \"$MEMORY_DIR/LOG.txt\"\n")
      File.chmod!(memo, 0o755)

      assert {"", 0} = boot.()
      assert File.read!(Path.join(home, ".optmem/memo")) == File.read!(memo)
      assert File.regular?(Path.join(home, ".optmem/memory/LOG.txt"))
    end
  end

  test "the standing text forbids the usual login steps and explains MDT's answers" do
    text = Instructions.text()
    assert text =~ "gh auth login"
    assert text =~ "mdt_grant_off"
    assert text =~ "/mnt/mdt/grants.md"
    assert text =~ "mdt request GRANT_ID --reason"
    assert text =~ "mdt request --need"
    assert text =~ "~/.optmem/memo wake"
  end

  test "the grants list says what each is for and how to use it, never values" do
    github = %Grant{
      id: "github",
      name: "GitHub",
      kind: :token,
      purpose: "Push to\nmy repos",
      state: :on,
      expires_at: ~U[2026-11-12 13:00:00Z],
      placeholder: "ghp_placeholder",
      env: ["GH_TOKEN"],
      git: true,
      hosts: ["api.github.com", "github.com"]
    }

    vpn = %Grant{
      id: "vpn",
      name: "VPN",
      kind: :network,
      purpose: "Grafana",
      destinations: ["10.0.0.0/8:443"],
      allowances: [%Allowance{id: "a", pattern: :all}],
      state: :on
    }

    text = Instructions.grants([github, vpn], ~U[2026-11-12 12:00:00Z])
    assert text =~ "## GitHub"
    assert text =~ "id: `github` · Token or API key · on until 13:00 UTC (60 min left)"
    assert text =~ "for: Push to my repos"
    assert text =~ "$GH_TOKEN, /mnt/mdt/tokens/github"
    assert text =~ "only to api.github.com, github.com"
    assert text =~ "git over HTTPS to api.github.com, github.com"
    assert text =~ "each request waits for the user's approval"
    assert text =~ "connect directly to 10.0.0.0/8:443"
    assert text =~ "every connection goes through for now"
    refute text =~ "ghp_placeholder"
    assert Instructions.grants([], ~U[2026-11-12 12:00:00Z]) =~ "No grants yet."
  end
end
