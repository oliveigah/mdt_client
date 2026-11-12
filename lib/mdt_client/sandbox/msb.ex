defmodule MDTClient.Sandbox.Msb do
  @moduledoc """
  The `msb` command line, which is how MDT drives microsandbox: there is no
  Elixir SDK. Every call runs under `timeout`, so a stuck `msb` cannot stall
  the sandbox process.

  The desktop app may start without `~/.local/bin` on its PATH, so the
  installer's own location is tried as well.
  """

  @doc "Where `msb` is, or nil when it is not installed."
  @spec executable() :: String.t() | nil
  def executable do
    installed = Path.join(System.user_home!(), ".microsandbox/bin/msb")

    cond do
      path = System.find_executable("msb") -> path
      File.exists?(installed) -> installed
      true -> nil
    end
  end

  @doc "Runs `msb` with `args`, giving up after `seconds`."
  @spec run([String.t()], pos_integer()) :: {:ok, String.t()} | {:error, String.t()}
  def run(args, seconds \\ 60) do
    case executable() do
      nil ->
        {:error, "msb is not installed"}

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

  @doc "The environment every `msb` call gets."
  @spec env() :: [{String.t(), String.t()}]
  def env, do: [{"MSB_BACKEND", "local"}, {"NO_COLOR", "1"}]

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
  @spec image?(String.t()) :: boolean()
  def image?(tag), do: match?({:ok, _}, run(["image", "inspect", tag], 20))

  @doc "The arguments of `msb create` for a VM with these parts."
  @spec create_args(map()) :: [String.t()]
  def create_args(
        %{
          name: name,
          image: image,
          cpus: cpus,
          memory_gib: memory,
          proxy_port: port,
          shell: shell
        } = vm
      ) do
    mounts =
      Enum.flat_map(vm.mounts, fn {host, guest, mode} ->
        ["--volume", "#{host}:#{guest}#{if mode == :ro, do: ":ro", else: ""}"]
      end)

    env = Enum.flat_map(vm.env, fn {key, value} -> ["--env", "#{key}=#{value}"] end)

    ["create", image, "--name", name, "--replace", "--pull", "never"] ++
      ["--shell", shell] ++
      ["--cpus", "#{cpus}", "--memory", "#{memory}G"] ++
      ["--proxy", "http://127.0.0.1:#{port}", "--net", "public,private"] ++
      mounts ++ env
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
