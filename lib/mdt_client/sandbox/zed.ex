defmodule MDTClient.Sandbox.Zed do
  @moduledoc """
  Opens a folder of the VM in Zed on your machine, as `zed
  ssh://mdt-sandbox/<folder>`.

  Zed reaches the VM through the `mdt-sandbox` entry in `~/.ssh/config`,
  which the Setup page writes out; MDT only opens it when that entry runs
  this identity's launcher (`MDTClient.Sandbox.Msb.ssh_entry/2`), so Zed
  never lands in a VM MDT doesn't run.

  Tests set `config :mdt_client, MDTClient.Sandbox.Zed, open: fun` to see
  the address instead of starting Zed.
  """

  alias MDTClient.Sandbox.Msb

  @ssh_host "mdt-sandbox"

  @type error :: :no_zed | :no_ssh_entry | {:other_ssh_entry, String.t()} | String.t()

  @doc "The host name the VM has in your SSH config."
  @spec ssh_host() :: String.t()
  def ssh_host, do: @ssh_host

  @doc "The address Zed opens a folder of the VM at."
  @spec url(Path.t()) :: String.t()
  def url(folder), do: "ssh://#{@ssh_host}#{folder}"

  @doc "The command that opens `folder` in Zed, for you to copy."
  @spec command(Path.t()) :: String.t()
  def command(folder), do: "zed #{url(folder)}"

  @doc "Opens `folder` of the VM in Zed."
  @spec open(String.t(), Path.t()) :: :ok | {:error, error()}
  def open(username, folder) do
    address = url(folder)

    case Application.get_env(:mdt_client, __MODULE__, [])[:open] do
      nil -> launch(username, address)
      fun -> fun.(address)
    end
  end

  defp launch(username, address) do
    with :ok <- entry(username),
         zed when is_binary(zed) <- executable() || {:error, :no_zed} do
      # Zed's command hands the address to Zed and returns; a Zed that
      # isn't running yet keeps it running, so it is not waited on.
      Task.start(fn -> System.cmd(zed, [address], stderr_to_stdout: true) end)
      :ok
    end
  end

  defp entry(username) do
    case Msb.ssh_entry(username, @ssh_host) do
      :ok -> :ok
      :missing -> {:error, :no_ssh_entry}
      {:other, command} -> {:error, {:other_ssh_entry, command}}
    end
  end

  # A desktop app may not have your shell's PATH.
  defp executable do
    Enum.find_value(["zed", "zeditor", "zed-editor"], &System.find_executable/1) ||
      Enum.find(
        [
          Path.expand("~/.local/bin/zed"),
          "/usr/bin/zeditor",
          "/var/lib/flatpak/exports/bin/dev.zed.Zed"
        ],
        &File.regular?/1
      )
  end

  @doc "Why Zed didn't open, in words."
  @spec explain(error()) :: String.t()
  def explain(:no_zed), do: "MDT can't find Zed's zed command on this machine."

  def explain(:no_ssh_entry),
    do:
      "Zed can't reach the VM yet: add the mdt-sandbox entry from the Setup page to ~/.ssh/config."

  def explain({:other_ssh_entry, _command}),
    do:
      "The mdt-sandbox entry in ~/.ssh/config reaches another VM. Use the one on the Setup page."

  def explain(text) when is_binary(text), do: text
end
