defmodule MDTClient.Sandbox.Msb do
  @moduledoc """
  The `msb` command line, which is how MDT drives microsandbox: there is no
  Elixir SDK. Every call runs under `timeout`, so a stuck `msb` cannot stall
  the sandbox process.

  MDT ships its own runtime, built by `scripts/build-microsandbox.sh` into
  `priv/microsandbox`: a pinned `msb` with MDT's live-sharing patch, and
  that release's libkrunfw, which `msb` finds beside its `bin/`. Whatever
  `msb` is on the PATH is never used.

  Its state (VMs, images, SSH keys) lives in MDT's own microsandbox home,
  not `~/.microsandbox`, so an `msb` you install yourself, at any version,
  neither sees MDT's VMs nor migrates their database. The launcher at
  `launcher/0` runs MDT's `msb` with that home, for Zed and for you.
  """

  alias MDTClient.Accounts

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

  @doc "MDT's microsandbox home: its VMs, images and SSH keys."
  @spec home() :: Path.t()
  def home, do: Path.join(Accounts.root(), "microsandbox")

  @doc "Where `write_launcher/0` puts the launcher."
  @spec launcher() :: Path.t()
  def launcher, do: Path.join([Accounts.root(), "bin", "msb"])

  @doc """
  Writes the launcher: a script that runs MDT's `msb` with MDT's home. Its
  path stays put when an MDT update moves the runtime, so Zed's SSH config
  keeps working; MDT rewrites it on start.
  """
  @spec write_launcher() :: :ok | {:error, term()}
  def write_launcher do
    case executable() do
      nil ->
        {:error, :no_runtime}

      msb ->
        path = launcher()

        script = """
        #!/bin/sh
        # Written by MDT on start: MDT's own msb, with MDT's microsandbox home.
        export MSB_HOME=#{shell_quote(home())}
        export MSB_PATH=#{shell_quote(msb)}
        exec "$MSB_PATH" "$@"
        """

        if File.read(path) == {:ok, script}, do: :ok, else: replace(path, script)
    end
  end

  # Every identity's sandbox writes it on start, so each write has its own
  # temporary file and the rename is atomic.
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

  @doc "Runs `msb` with `args`, giving up after `seconds`."
  @spec run([String.t()], pos_integer()) :: {:ok, String.t()} | {:error, String.t()}
  def run(args, seconds \\ 60) do
    case executable() do
      nil ->
        {:error, "MDT's msb is missing"}

      msb ->
        case System.cmd("timeout", ["--kill-after=5", "#{seconds}", msb | args],
               stderr_to_stdout: true,
               env: env()
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
  @spec env() :: [{String.t(), String.t()}]
  def env do
    path = if msb = executable(), do: [{"MSB_PATH", msb}], else: []
    [{"MSB_BACKEND", "local"}, {"NO_COLOR", "1"}, {"MSB_HOME", home()} | path]
  end

  @doc "The VM's status as microsandbox reports it, or `:missing`."
  @spec status(String.t()) ::
          {:ok, :running | :stopped | :starting | :stopping | :crashed}
          | :missing
          | {:error, String.t()}
  def status(name) do
    with {:ok, output} <- run(["inspect", name, "--format", "json"], 20),
         {:ok, %{"status" => status}} <- Jason.decode(output) do
      {:ok, normalize(status)}
    else
      {:error, message} when is_binary(message) ->
        if message =~ ~r/not found|no such|does not exist/i, do: :missing, else: {:error, message}

      _other ->
        {:error, "msb inspect returned something unexpected"}
    end
  end

  @doc "Whether an image tag is in microsandbox's cache."
  @spec image?(String.t() | nil) :: boolean()
  def image?(nil), do: false
  def image?(tag), do: match?({:ok, _}, run(["image", "inspect", tag], 20))

  @doc "The arguments of `msb create` for a VM with these parts."
  @spec create_args(map()) :: [String.t()]
  def create_args(
        %{
          name: name,
          image: image,
          cpus: cpus,
          memory_gib: memory,
          disk_gib: disk,
          write_budget_gib: budget,
          proxy_port: port,
          shell: shell
        } = vm
      ) do
    # microsandbox caps what the VM adds to each mounted folder per boot (4
    # GiB unless told); read-only folders take no writes at all.
    mounts =
      Enum.flat_map(vm.mounts, fn
        {host, guest, :ro} -> ["--volume", "#{host}:#{guest}:ro"]
        {host, guest, :rw} -> ["--volume", "#{host}:#{guest}:quota=#{budget}G"]
      end)

    env = Enum.flat_map(vm.env, fn {key, value} -> ["--env", "#{key}=#{value}"] end)

    # The agent channel: the VM's vsock port, joined to MDT's socket.
    vsock =
      case vm[:vsock] do
        nil -> []
        path -> ["--vsock", "#{path}:#{MDTClient.Sandbox.Channel.port()}"]
      end

    ["create", image, "--name", name, "--replace", "--pull", "never"] ++
      ["--shell", shell] ++
      ["--cpus", "#{cpus}", "--memory", "#{memory}G", "--root-disk", "#{disk}G"] ++
      ["--proxy", "http://127.0.0.1:#{port}", "--net", "public,private"] ++
      vsock ++ mounts ++ env
  end

  defp normalize(status) do
    case String.downcase(status) do
      "running" -> :running
      "stopped" -> :stopped
      "created" -> :stopped
      "starting" -> :starting
      "stopping" -> :stopping
      "paused" -> :stopped
      _other -> :crashed
    end
  end
end
