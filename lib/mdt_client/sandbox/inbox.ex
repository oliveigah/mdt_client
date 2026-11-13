defmodule MDTClient.Sandbox.Inbox do
  @moduledoc """
  The folder the VM reads at `/mnt/mdt`, read-only, live. The image only
  points here, so everything that belongs to one identity or to this version
  of MDT arrives this way:

    * `ca.pem`, `ca-bundle.pem` - the identity's CA, alone and appended to
      this machine's trusted roots; the image links its system bundle to the
      second;
    * `profile.sh`, `bashrc.sh`, `env.sh` - the shell's tool paths,
      interactive defaults and placeholders of every token grant;
    * `bin/mdt` - the command agents ask MDT for access with
      (`MDTClient.Sandbox.Channel`);
    * `bin/git-credential`, `git/<host>` - git's answers for the hosts of
      token grants that answer git;
    * `tokens/<grant>` - each token grant's placeholder, as a file;
    * `files/` - the real value of file grants that are on;
    * `AGENTS.md`, `grants.md` - what agents are told, and the grants as they
      are now;
    * `host.md` - your machine, for writing host commands
      (`MDTClient.Sandbox.HostInfo`), written by `write_host/2`.

  Everything here but `files/` is worthless outside MDT's proxy. A file grant
  writes the real value, which is why turning it off deletes it and why
  copies survive.
  """

  alias MDTClient.Sandbox.{Grant, Instructions}

  @doc """
  Rewrites the inbox from the grants, the values of those that are on, and
  the identity's CA certificate.
  """
  @spec write(Path.t(), [Grant.t()], %{String.t() => binary()}, String.t()) :: :ok
  def write(dir, grants, values, ca_pem) do
    File.mkdir_p!(dir)

    for sub <- ["git", "tokens", "files"] do
      File.rm_rf!(Path.join(dir, sub))
      File.mkdir_p!(Path.join(dir, sub))
    end

    put_changed(dir, "ca.pem", ca_pem)
    put_changed(dir, "ca-bundle.pem", bundle(ca_pem))
    put_changed(dir, "profile.sh", priv("mdt-profile.sh"))
    put_changed(dir, "bashrc.sh", priv("mdt-bashrc.sh"))
    put_changed(dir, "bin/git-credential", priv("mdt-git-credential"), 0o755)
    put_changed(dir, "bin/mdt", priv("mdt-cli"), 0o755)
    put_changed(dir, "AGENTS.md", Instructions.text())

    tokens = Enum.filter(grants, &(&1.kind == :token))

    put(dir, "env.sh", env_script(tokens))
    put(dir, "grants.md", Instructions.grants(grants, DateTime.utc_now()))

    for grant <- tokens, host <- Grant.git_hosts(grant) do
      put(
        dir,
        Path.join("git", host),
        "protocol=https\nhost=#{host}\nusername=x-access-token\npassword=#{grant.placeholder}\n"
      )
    end

    for grant <- tokens do
      put(dir, Path.join("tokens", grant.id), grant.placeholder)
    end

    for %Grant{kind: :file, state: :on} = grant <- grants, value = values[grant.id] do
      put(dir, Path.join("files", Path.basename(grant.path)), value, 0o600)
    end

    :ok
  end

  @doc "Writes `host.md`, the description of your machine that `mdt host` also prints."
  @spec write_host(Path.t(), String.t()) :: :ok
  def write_host(dir, text), do: put_changed(dir, "host.md", text)

  @doc """
  The environment the VM's processes get from token grants: `env` variables
  hold the placeholder, `file_env` variables the path of the file holding it.
  """
  @spec env([Grant.t()]) :: [{String.t(), String.t()}]
  def env(grants) do
    for %Grant{kind: :token} = grant <- grants,
        pair <-
          Enum.map(grant.env, &{&1, grant.placeholder}) ++
            Enum.map(grant.file_env, &{&1, Grant.token_file(grant)}),
        do: pair
  end

  @doc """
  The VM's CA bundle: the roots this machine trusts, then the identity's CA.
  The guest's own bundle would do as well, but it isn't known until the image
  runs, and these are the same public roots.
  """
  @spec bundle(String.t()) :: String.t()
  def bundle(ca_pem) do
    roots =
      try do
        :public_key.cacerts_get()
        |> Enum.map(fn {:cert, der, _decoded} -> {:Certificate, der, :not_encrypted} end)
        |> :public_key.pem_encode()
      rescue
        _ -> ""
      end

    roots <> ca_pem
  end

  defp env_script(grants) do
    lines = for {var, value} <- env(grants), do: "export #{var}='#{value}'\n"

    "# Written by MDT. Placeholders only: MDT swaps in real values on the way out.\n" <>
      Enum.join(lines)
  end

  # Files that rarely change are left untouched when they haven't, so the VM
  # never sees them rewritten for nothing.
  defp put_changed(dir, name, data, mode \\ 0o644) do
    case File.read(Path.join(dir, name)) do
      {:ok, ^data} -> :ok
      _ -> put(dir, name, data, mode)
    end
  end

  # Written aside and renamed, so the VM never reads half a file.
  defp put(dir, name, data, mode \\ 0o644) do
    path = Path.join(dir, name)
    File.mkdir_p!(Path.dirname(path))
    partial = path <> ".part"
    File.write!(partial, data)
    File.chmod!(partial, mode)
    File.rename!(partial, path)
  end

  defp priv(name), do: File.read!(Path.join([:code.priv_dir(:mdt_client), "sandbox", name]))
end
