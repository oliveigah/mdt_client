defmodule MDTClient.Sandbox.Sockets do
  @moduledoc """
  The folder of Unix sockets between MDT and one identity's VM. The VM's
  bubble has no network, so these are every way in and out of it
  (`/mdt/sockets` in there):

    * `proxy.sock` - the egress proxy (`MDTClient.Sandbox.Egress`);
    * `dns.sock` - the DNS forwarder (`MDTClient.Sandbox.Dns`);
    * `channel.sock` - the agent channel (`MDTClient.Sandbox.Channel`),
      joined to the VM's vsock;
    * `control.sock`, `relay.lock`, `start.out`, `bubble.pid`, `bubble.log` -
      the relay's own (`MDTClient.Sandbox.Bubble`).

  It sits in `$XDG_RUNTIME_DIR/mdt/<id>`, readable by you only: Unix socket
  paths are short (108 bytes), too short for the identity's own folder, and
  the runtime directory is gone after a logout, like the VM. Tests set
  `:channel_dir`.
  """

  alias MDTClient.Accounts
  alias MDTClient.Sandbox.Server

  @doc "The identity's folder of sockets."
  @spec dir(String.t()) :: Path.t()
  def dir(username), do: Path.join(base(), String.slice(Accounts.id(username), 0, 12))

  @doc "One file in it."
  @spec path(String.t(), String.t()) :: Path.t()
  def path(username, name), do: Path.join(dir(username), name)

  @doc "Creates the folder, for you only, and returns it."
  @spec ensure!(String.t()) :: Path.t()
  def ensure!(username) do
    dir = dir(username)
    File.mkdir_p!(dir)
    File.chmod!(Path.dirname(dir), 0o700)
    File.chmod!(dir, 0o700)
    dir
  end

  defp base do
    config = Application.get_env(:mdt_client, Server, [])

    Keyword.get_lazy(config, :channel_dir, fn ->
      case System.get_env("XDG_RUNTIME_DIR") do
        runtime when is_binary(runtime) and runtime != "" -> Path.join(runtime, "mdt")
        _ -> Path.join(System.tmp_dir!(), "mdt-#{System.get_env("USER", "user")}")
      end
    end)
  end
end
