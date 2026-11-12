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

  test "Claude Code and Codex both get the block in Home" do
    home = Path.join(System.tmp_dir!(), "home-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(home) end)
    File.mkdir_p!(Path.join(home, ".codex"))
    File.write!(Path.join(home, ".codex/AGENTS.md"), "Prefer small commits.\n")

    :ok = Instructions.write_home!(home, Instructions.text())

    claude = File.read!(Path.join(home, ".claude/CLAUDE.md"))
    codex = File.read!(Path.join(home, ".codex/AGENTS.md"))
    assert claude =~ "Access comes only from MDT"
    assert codex =~ "Access comes only from MDT"
    assert codex =~ "Prefer small commits."
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
