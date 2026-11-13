defmodule MDTClient.Sandbox.Forwarder.SSH do
  @moduledoc """
  The tunnel `MDTClient.Sandbox.Forwarder` uses with a real VM: OpenSSH as
  a control master, through `msb ssh serve VM --stdio`.

  msb's SSH server carries forwarded connections (`direct-tcpip`) over its
  own channel to the VM's agent, which connects inside the VM, so servers on
  the VM's loopback can be reached. Forwards are added and removed on the
  master (`ssh -O forward|cancel`).

  The listing (`ss -ltnpH`) runs with `msb exec`, not over the master: msb
  0.7.14's SSH server keeps one agent connection per command until the
  connection ends (it closes the channel first, and russh never reports the
  client's close back), and the VM's agent takes 128 at most. Listing every
  2 seconds over the master used them up in about 4 minutes; the next
  command failed, msb ended the session, and every forward with it
  ("client_loop: send disconnect: Broken pipe"). `msb exec` exits after
  each listing, which frees its connection.

    * The key is MDT's own, made on first use (`ssh-keygen`, no passphrase)
      and added with `msb ssh authorize` on each open; msb ignores a key it
      already has.
    * No `~/.ssh/config` (`-F /dev/null`), no prompts (`BatchMode`), no
      known hosts: the transport is msb's process, not a network.
    * The master runs under a wrapper that ends it when its stdin closes, so
      it never outlives MDT.
  """

  @behaviour MDTClient.Sandbox.Forwarder

  alias MDTClient.Sandbox.Msb

  # `$@` is ssh. Background jobs get /dev/null as stdin, so the watcher
  # reads MDT's end through fd 3. It writes nowhere: holding the port's
  # output open would keep MDT from hearing that ssh ended. The wrapper ends
  # when ssh does.
  @wrapper ~S"""
  exec 3<&0
  "$@" &
  ssh=$!
  { cat <&3; kill "$ssh"; } >/dev/null 2>&1 &
  wait "$ssh"
  """

  @control_timeout 10

  @impl true
  def open(%{vm: vm, key: key, control: control}) do
    with {:ok, ssh} <- find("ssh"),
         {:ok, msb} <- msb(),
         :ok <- ensure_key(key),
         :ok <- authorize(key <> ".pub") do
      dir = Path.dirname(control)
      File.mkdir_p!(dir)
      File.chmod!(dir, 0o700)
      _ = File.rm(control)

      port =
        Port.open({:spawn_executable, System.find_executable("bash") || "/bin/bash"}, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          env:
            Enum.map(Msb.env(), fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end),
          args: ["-c", @wrapper, "mdt-forward", ssh | master_args(vm, msb, key, control)]
        ])

      {:ok, %{port: port, ssh: ssh, control: control, host: host(vm), vm: vm}}
    end
  end

  @doc false
  def master_args(vm, msb, key, control) do
    ["-M", "-N", "-n", "-S", control, "-F", "/dev/null", "-i", key] ++
      options([
        "IdentitiesOnly=yes",
        "BatchMode=yes",
        "StrictHostKeyChecking=no",
        "UserKnownHostsFile=/dev/null",
        "LogLevel=ERROR",
        "ServerAliveInterval=15",
        "ServerAliveCountMax=3",
        "ExitOnForwardFailure=no",
        "ProxyCommand=#{shell_quote(msb)} ssh serve #{shell_quote(vm)} --stdio --no-inactivity-timeout"
      ]) ++ [host(vm)]
  end

  @impl true
  def listeners(conn) do
    case Msb.run(listing_args(conn.vm), @control_timeout) do
      {:ok, output} -> {:ok, output}
      {:error, message} -> {:error, last_line(message, 1)}
    end
  end

  # As root, like the master's user, so `-p` names every server's process.
  @doc false
  def listing_args(vm),
    do: ["exec", vm, "--user", "root", "--quiet", "--no-tty", "--no-stdin", "--", "ss", "-ltnpH"]

  @impl true
  def forward(conn, address, port, target) do
    case control(conn, ["-O", "forward", "-L", spec(address, port, target), conn.host]) do
      {_output, 0} -> :ok
      {output, status} -> {:error, last_line(output, status)}
    end
  end

  @impl true
  def cancel(conn, address, port, target) do
    control(conn, ["-O", "cancel", "-L", spec(address, port, target), conn.host])
    :ok
  end

  @impl true
  def close(conn) do
    control(conn, ["-O", "exit", conn.host])
    Port.close(conn.port)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc false
  def spec(address, port, target), do: "#{address}:#{port}:#{bracket(target)}:#{port}"

  defp bracket(target), do: if(String.contains?(target, ":"), do: "[#{target}]", else: target)

  defp control(conn, args) do
    System.cmd(
      "timeout",
      ["#{@control_timeout}", conn.ssh, "-S", conn.control, "-F", "/dev/null"] ++
        options(["BatchMode=yes", "LogLevel=ERROR"]) ++ args,
      stderr_to_stdout: true
    )
  end

  defp options(options), do: Enum.flat_map(options, &["-o", &1])

  defp host(vm), do: "root@" <> vm

  defp last_line(output, status) do
    case output |> String.trim() |> String.split("\n") |> List.last() do
      line when line in [nil, ""] -> "ssh exited #{status}"
      line -> line
    end
  end

  defp find(name) do
    case System.find_executable(name) do
      nil -> {:error, "#{name} isn't installed on this machine"}
      path -> {:ok, path}
    end
  end

  defp msb do
    case Msb.executable() do
      nil -> {:error, "MDT's msb is missing"}
      path -> {:ok, path}
    end
  end

  defp ensure_key(key) do
    if File.exists?(key) and File.exists?(key <> ".pub") do
      :ok
    else
      _ = File.rm(key)
      _ = File.rm(key <> ".pub")
      File.mkdir_p!(Path.dirname(key))

      case System.cmd(
             "ssh-keygen",
             ["-q", "-t", "ed25519", "-N", "", "-C", "MDT port forwarding", "-f", key],
             stderr_to_stdout: true
           ) do
        {_output, 0} -> :ok
        {output, _status} -> {:error, "Couldn't make MDT's SSH key: " <> String.trim(output)}
      end
    end
  end

  defp authorize(public_key) do
    case Msb.run(["ssh", "authorize", "--file", public_key], 20) do
      {:ok, _output} -> :ok
      {:error, message} -> {:error, "msb ssh authorize failed: " <> message}
    end
  end

  # For the shell ssh runs ProxyCommand with.
  defp shell_quote(text), do: "'" <> String.replace(text, "'", ~S('\'')) <> "'"
end
