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
      recipe: :github,
      kind: :http,
      placeholder: "ghp_placeholder",
      env: ["GH_TOKEN"],
      hosts: ["github.com"]
    }

    :ok = Inbox.write(dir, [grant], %{"github" => "ghp_real"}, ca)

    assert File.read!(Path.join(dir, "ca.pem")) == ca
    assert String.ends_with?(File.read!(Path.join(dir, "ca-bundle.pem")), ca)
    assert File.read!(Path.join(dir, "env.sh")) =~ "export GH_TOKEN='ghp_placeholder'"
    assert File.read!(Path.join(dir, "profile.sh")) =~ "/mnt/mdt/env.sh"
    assert File.read!(Path.join(dir, "bashrc.sh")) =~ "/mnt/mdt/profile.sh"
    assert %File.Stat{mode: mode} = File.stat!(Path.join(dir, "bin/git-credential"))
    assert Bitwise.band(mode, 0o111) != 0
    assert File.read!(Path.join(dir, "AGENTS.md")) =~ "Access comes only from MDT"
    assert File.read!(Path.join(dir, "grants.md")) =~ "| GitHub |"
    assert File.read!(Path.join(dir, "git/github.com")) =~ "password=ghp_placeholder"

    for file <- Path.wildcard(Path.join(dir, "**/*"), match_dot: true), File.regular?(file) do
      refute File.read!(file) =~ "ghp_real", "#{file} holds the real value"
    end
  end
end
