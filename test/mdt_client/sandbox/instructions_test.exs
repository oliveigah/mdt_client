defmodule MDTClient.Sandbox.InstructionsTest do
  use ExUnit.Case, async: true

  alias MDTClient.Sandbox.{Grant, Instructions, Recipes, Rule}

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
    assert text =~ "~/.optmem/memo wake"
  end

  test "grants.md names grants, variables and rules, never values" do
    github = Recipes.fetch!(:github)

    grant = %Grant{
      id: "github",
      name: "GitHub",
      recipe: :github,
      kind: :http,
      state: :on,
      placeholder: "ghp_placeholder",
      env: ["GH_TOKEN"],
      hosts: ["api.github.com", "github.com"],
      rules: [%Rule{id: "r", label: "Reads", match: "read", action: :allow, tag: "read"}],
      default_action: :ask
    }

    text = Instructions.grants([grant], ~U[2026-11-12 12:00:00Z])
    assert text =~ "| GitHub | #{github.name} | on |"
    assert text =~ "`GH_TOKEN` (placeholders)"
    assert text =~ "Reads: go through; anything else: wait for the user"
    refute text =~ "ghp_placeholder"
    assert Instructions.grants([], ~U[2026-11-12 12:00:00Z]) =~ "No grants yet."
  end
end
