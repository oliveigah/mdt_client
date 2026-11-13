defmodule MDTClient.Sandbox.Msb do
  @moduledoc """
  The `msb` command line, which is how MDT drives microsandbox: there is no
  Elixir SDK. Every call runs under `timeout`, so a stuck `msb` cannot stall
  the sandbox process.

  MDT ships its own runtime, built by `scripts/build-microsandbox.sh` into
  `priv/microsandbox`: `msb` from a pinned commit of MDT's fork
  (oliveigah/microsandbox, an upstream release plus the fix for files the
  host replaces), that release's libkrunfw, which `msb` finds beside its
  `bin/`, and MDT's relay. Whatever `msb` is on the PATH is never used.

  Each identity has its own microsandbox home, in its sandbox folder, not
  `~/.microsandbox`: an `msb` you install yourself, at any version, neither
  sees MDT's VMs nor migrates their database, and one identity's VM never
  sees another's.

  The VM's own process never runs from here: it is started and stopped in a
  bubble (`MDTClient.Sandbox.Bubble`). What runs on the host is `msb` for
  images, for the VM's record, and for going into a running VM.
  """

  alias MDTClient.Accounts
  alias MDTClient.Sandbox.{Bubble, Channel, Disks, Sockets}

  @doc "The folder holding MDT's runtime: `bin/msb` and `lib/libkrunfw.so.*`."
  @spec runtime_dir() :: Path.t()
  def runtime_dir do
    Keyword.get_lazy(config(), :runtime_dir, fn ->
      Application.app_dir(:mdt_client, "priv/microsandbox")
    end)
  end

  @doc "MDT's `msb`, or nil when this build has no runtime."
  @spec executable() :: String.t() | nil
  def executable do
    path = Path.join(runtime_dir(), "bin/msb")
    if File.regular?(path), do: path
  end

  @doc """
  Where one identity's microsandbox home is kept: its VM, images and SSH
  keys. Each identity has its own, in its sandbox folder, so the bubble of
  one never holds another's VM.
  """
  @spec store(String.t()) :: Path.t()
  def store(username), do: Path.join([Accounts.dir(username), "sandbox", "microsandbox"])

  @doc """
  The path `msb` is given as its home (`MSB_HOME`): a link to `store/1`,
  beside the identity's sockets. microsandbox keeps Unix sockets of its own
  under its home, and a socket's path must fit in 108 bytes, which the
  identity's folder is too deep for. What it records of its images it
  records by their real path, so the link can move.
  """
  @spec home(String.t()) :: Path.t()
  def home(username), do: Sockets.path(username, "msb")

  @doc "Makes the home and the link to it, and returns the link."
  @spec ensure_home!(String.t()) :: Path.t()
  def ensure_home!(username) do
    store = store(username)
    home = home(username)
    File.mkdir_p!(store)

    # msb takes no store that another account could swap a folder of: no
    # folder above it may be writable by a group or by everyone. A login
    # umask of 002, Ubuntu's, makes every new folder exactly that. MDT's
    # folders are nobody else's to read either.
    for dir <- mdt_folders(store), do: File.chmod!(dir, 0o700)
    Sockets.ensure!(username)

    if File.read_link(home) != {:ok, store} do
      File.rm_rf!(home)
      File.ln_s!(store, home)
    end

    home
  end

  # A path and the folders above it, up to MDT's own data folder.
  defp mdt_folders(path) do
    root = Accounts.root()

    if String.starts_with?(path, root <> "/"),
      do: path |> Stream.iterate(&Path.dirname/1) |> Enum.take_while(&(&1 != Path.dirname(root))),
      else: [path]
  end

  @doc """
  The command `ssh` runs to reach `host`, read from the text of an SSH
  config: the first `ProxyCommand` in a `Host` block that names `host`, as
  ssh itself takes the first value it finds. Nil when there is none.
  `Include` and `Match` are not followed.

      iex> config = "Host other\\n  ProxyCommand nc a 22\\nHost mdt-sandbox\\n  User root\\n  ProxyCommand /x/msb ssh serve vm --stdio\\n"
      iex> MDTClient.Sandbox.Msb.proxy_command(config, "mdt-sandbox")
      "/x/msb ssh serve vm --stdio"

      iex> MDTClient.Sandbox.Msb.proxy_command("Host *\\n  ProxyCommand=/y/msb ssh\\n", "mdt-sandbox")
      nil
  """
  @spec proxy_command(String.t(), String.t()) :: String.t() | nil
  def proxy_command(text, host) do
    text
    |> String.split(["\r\n", "\n"])
    |> Enum.reduce_while(false, fn line, in_block? ->
      case Regex.run(~r/\A\s*([A-Za-z]+)\s*(?:=|\s)\s*(.*?)\s*\z/, line) do
        [_, keyword, value] ->
          case String.downcase(keyword) do
            "host" -> {:cont, host in String.split(value)}
            "match" -> {:cont, false}
            "proxycommand" when in_block? -> {:halt, {:found, value}}
            _other -> {:cont, in_block?}
          end

        nil ->
          {:cont, in_block?}
      end
    end)
    |> case do
      {:found, command} -> command
      _none -> nil
    end
  end

  @doc """
  How your SSH config (`~/.ssh/config`) reaches `host`: `:ok` through this
  identity's launcher, `{:other, command}` through something else, or
  `:missing`. Something else is how Zed ends up in a VM MDT no longer runs:
  a launcher of an older MDT, say, which runs another microsandbox home.
  Tests point `config :mdt_client, MDTClient.Sandbox.Msb, ssh_config:`
  elsewhere.
  """
  @spec ssh_entry(String.t(), String.t()) :: :ok | :missing | {:other, String.t()}
  def ssh_entry(username, host) do
    path = Keyword.get_lazy(config(), :ssh_config, fn -> Path.expand("~/.ssh/config") end)

    with {:ok, text} <- File.read(path),
         command when is_binary(command) <- proxy_command(text, host) do
      program = command |> String.split() |> List.first("") |> Path.expand()
      if program == launcher(username), do: :ok, else: {:other, command}
    else
      _none -> :missing
    end
  end

  @doc "Where `write_launcher/1` puts an identity's launcher."
  @spec launcher(String.t()) :: Path.t()
  def launcher(username), do: Path.join([Accounts.dir(username), "sandbox", "bin", "msb"])

  @doc """
  Writes the identity's launcher: a script that runs MDT's `msb` with that
  identity's home, for Zed's SSH config and for you. Its path stays put when
  an MDT update moves the runtime; MDT rewrites it on start.

  It only looks at the VM and goes into it. msb boots a stopped VM by itself
  on `exec` and `ssh`, outside MDT's bubble, so those are refused while the
  VM isn't running (the relay holds `relay.lock` while it is), and what
  starts, stops or changes the VM is refused always: MDT does that.
  """
  @spec write_launcher(String.t()) :: :ok | {:error, term()}
  def write_launcher(username) do
    case executable() do
      nil ->
        {:error, :no_runtime}

      msb ->
        path = launcher(username)

        script = """
        #!/bin/sh
        # Written by MDT on start: MDT's own msb, for this identity's VM.
        store=#{shell_quote(store(username))}
        export MSB_HOME=#{shell_quote(home(username))}
        export MSB_PATH=#{shell_quote(msb)}
        export MSB_BACKEND=local
        lock=#{shell_quote(Sockets.path(username, "relay.lock"))}
        # msb's home is a short link to its real folder; after a reboot it
        # is gone until MDT or this script puts it back.
        if [ "$(readlink "$MSB_HOME" 2>/dev/null)" != "$store" ]; then
          mkdir -p "$store" "$(dirname "$MSB_HOME")" && rm -rf "$MSB_HOME" &&
            ln -s "$store" "$MSB_HOME" || exit 1
        fi
        case "${1:-}" in
          ls|list|status|ps|inspect|metrics|logs|df|ping|jobs|help|--help|-h|--version|-V)
            ;;
          exec|ssh|cp|copy|attach|signal|kill|eof|touch)
            if [ ! -e "$lock" ] || flock --nonblock "$lock" true 2>/dev/null; then
              echo "MDT's VM isn't running. Start it in MDT." >&2
              exit 1
            fi
            ;;
          *)
            echo "MDT starts, stops and changes its VM itself: msb ${1:-} isn't available here." >&2
            exit 1
            ;;
        esac
        exec "$MSB_PATH" "$@"
        """

        if File.read(path) == {:ok, script}, do: :ok, else: replace(path, script)
    end
  end

  defp replace(path, content) do
    temporary = "#{path}.#{System.unique_integer([:positive])}.tmp"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(temporary, content),
         :ok <- File.chmod(temporary, 0o755) do
      File.rename(temporary, path)
    end
  end

  defp shell_quote(text), do: "'" <> String.replace(text, "'", ~S('\'')) <> "'"

  defp config, do: Application.get_env(:mdt_client, __MODULE__, [])

  @doc """
  Runs `msb` with `args` on the host, in an identity's home, giving up after
  `seconds`. For what needs no VM process: images, the VM's record, and
  going into a VM that runs (`exec`). Starting and stopping go through
  `MDTClient.Sandbox.Bubble`.
  """
  @spec run(String.t(), [String.t()], pos_integer()) :: {:ok, String.t()} | {:error, String.t()}
  def run(username, args, seconds \\ 60) do
    case executable() do
      nil ->
        {:error, "MDT's msb is missing"}

      msb ->
        ensure_home!(username)

        case System.cmd("timeout", ["--kill-after=5", "#{seconds}", msb | args],
               stderr_to_stdout: true,
               env: env(username)
             ) do
          {output, 0} -> {:ok, output}
          {_output, 124} -> {:error, "msb #{hd(args)} took longer than #{seconds} s"}
          {output, _status} -> {:error, String.trim(output)}
        end
    end
  end

  @doc """
  The environment every `msb` call gets. `MSB_PATH` names the binary that
  VMs are spawned with, so a stray one in MDT's own environment can't pair
  MDT's `msb` with another.
  """
  @spec env(String.t()) :: [{String.t(), String.t()}]
  def env(username) do
    path = if msb = executable(), do: [{"MSB_PATH", msb}], else: []
    [{"MSB_BACKEND", "local"}, {"NO_COLOR", "1"}, {"MSB_HOME", home(username)} | path]
  end

  @doc """
  Whether the identity's VM exists in microsandbox's records: `:exists` or
  `:missing`. Whether it runs is the relay's to say
  (`MDTClient.Sandbox.Bubble.status/1`): msb records the VM's process id as
  the bubble sees it, which means nothing out here.
  """
  @spec status(String.t(), String.t()) :: :exists | :missing | {:error, String.t()}
  def status(username, name) do
    case run(username, ["inspect", name, "--format", "json"], 20) do
      {:ok, _record} ->
        :exists

      {:error, message} ->
        if message =~ ~r/not found|no such|does not exist/i, do: :missing, else: {:error, message}
    end
  end

  @doc "Whether an image tag is in the identity's microsandbox cache."
  @spec image?(String.t(), String.t() | nil) :: boolean()
  def image?(_username, nil), do: false
  def image?(username, tag), do: match?({:ok, _}, run(username, ["image", "inspect", tag], 20))

  @doc """
  The arguments of `msb create` for a VM with these parts, to run in the
  bubble: every disk and folder is named by its path there
  (`MDTClient.Sandbox.Bubble.inside/1`), and the proxy and DNS by the
  relay's loopback ports.
  """
  @spec create_args(map()) :: [String.t()]
  def create_args(
        %{
          name: name,
          image: image,
          cpus: cpus,
          memory_gib: memory,
          disk_gib: disk,
          write_budget_gib: budget,
          shell: shell
        } = vm
      ) do
    disks =
      Enum.flat_map(Disks.names(), fn disk ->
        ["--mount-disk", "#{Bubble.inside(:disks)}/#{disk}.img:#{Disks.mount_point(disk)}"]
      end)

    # microsandbox caps what the VM adds to each mounted folder per boot (4
    # GiB unless told); read-only folders take no writes at all.
    folders = [
      "--volume",
      "#{Bubble.inside(:inbox)}:/mnt/mdt:ro",
      "--volume",
      "#{Bubble.inside(:optmem)}:/root/.optmem:quota=#{budget}G"
    ]

    # A shared folder sits at the same path in the VM as on your machine.
    shares =
      vm.shares
      |> Enum.with_index()
      |> Enum.flat_map(fn
        {{path, :ro}, index} ->
          ["--volume", "#{Bubble.inside({:share, index})}:#{path}:ro"]

        {{path, :rw}, index} ->
          ["--volume", "#{Bubble.inside({:share, index})}:#{path}:quota=#{budget}G"]
      end)

    env = Enum.flat_map(vm.env, fn {key, value} -> ["--env", "#{key}=#{value}"] end)

    # Ports that exist only in the bubble, where the relay joins them to MDT.
    # The agent channel: the VM's vsock port, joined to MDT's socket.
    ["create", image, "--name", name, "--replace", "--pull", "never"] ++
      ["--shell", shell] ++
      ["--cpus", "#{cpus}", "--memory", "#{memory}G", "--root-disk", "#{disk}G"] ++
      ["--proxy", "http://127.0.0.1:3128", "--dns-nameserver", "127.0.0.1:5353"] ++
      ["--net", "public,private"] ++
      ["--vsock", "#{Bubble.inside(:sockets)}/channel.sock:#{Channel.port()}"] ++
      disks ++ folders ++ shares ++ env
  end
end
