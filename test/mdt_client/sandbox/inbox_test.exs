defmodule MDTClient.Sandbox.InboxTest do
  use ExUnit.Case, async: true

  alias MDTClient.Sandbox.{CertificateAuthority, Grant, Inbox}

  test "the inbox carries everything the image points at" do
    dir = Path.join(System.tmp_dir!(), "inbox-test-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    ca = CertificateAuthority.new() |> Map.fetch!(:cert) |> CertificateAuthority.pem()

    grant = %Grant{
      id: "github",
      name: "GitHub",
      kind: :token,
      purpose: "Push to my repos",
      placeholder: "ghp_placeholder",
      env: ["GH_TOKEN"],
      file_env: ["GH_TOKEN_FILE"],
      git: true,
      hosts: ["github.com", "*.github.com"]
    }

    :ok = Inbox.write(dir, [grant], %{"github" => "ghp_real"}, ca)

    assert File.read!(Path.join(dir, "ca.pem")) == ca
    assert String.ends_with?(File.read!(Path.join(dir, "ca-bundle.pem")), ca)
    assert File.read!(Path.join(dir, "env.sh")) =~ "export GH_TOKEN='ghp_placeholder'"
    assert File.read!(Path.join(dir, "env.sh")) =~ "export GH_TOKEN_FILE='/mnt/mdt/tokens/github'"
    assert File.read!(Path.join(dir, "tokens/github")) == "ghp_placeholder"
    assert File.read!(Path.join(dir, "profile.sh")) =~ "/mnt/mdt/env.sh"
    assert File.read!(Path.join(dir, "bashrc.sh")) =~ "/mnt/mdt/profile.sh"

    for command <- ["bin/git-credential", "bin/mdt"] do
      assert %File.Stat{mode: mode} = File.stat!(Path.join(dir, command))
      assert Bitwise.band(mode, 0o111) != 0
    end

    assert File.read!(Path.join(dir, "AGENTS.md")) =~ "Access comes only from MDT"
    assert File.read!(Path.join(dir, "grants.md")) =~ "## GitHub"
    assert File.read!(Path.join(dir, "git/github.com")) =~ "password=ghp_placeholder"
    # git asks by exact host; a wildcard has no file of its own.
    assert File.ls!(Path.join(dir, "git")) == ["github.com"]

    for file <- Path.wildcard(Path.join(dir, "**/*"), match_dot: true), File.regular?(file) do
      refute File.read!(file) =~ "ghp_real", "#{file} holds the real value"
    end
  end
end
