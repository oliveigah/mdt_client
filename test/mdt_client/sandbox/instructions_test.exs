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

      boot = fn ->
        System.cmd(
          "bash",
          [Path.join([:code.priv_dir(:mdt_client), "sandbox", "mdt-boot"])],
          env: [{"MDT_INBOX", inbox}, {"HOME", home}],
          stderr_to_stdout: true
        )
      end

      %{inbox: inbox, home: home, boot: boot}
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
