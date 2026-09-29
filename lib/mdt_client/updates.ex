defmodule MDTClient.Updates do
  @moduledoc """
  Checks the latest GitHub release only when asked and upgrades the installed
  Linux package after a separate confirmation. Network and package operations
  run outside the GenServer so the interface stays responsive.
  """

  use GenServer

  require Logger

  @topic "mdt:updates"
  @release_url "https://api.github.com/repos/oliveigah/mdt_client/releases/latest"
  @request_options [
    headers: [{"user-agent", "MDT updater"}, {"accept", "application/vnd.github+json"}],
    receive_timeout: 30_000,
    retry: false
  ]

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def subscribe, do: Phoenix.PubSub.subscribe(MDTClient.PubSub, @topic)
  def current, do: GenServer.call(__MODULE__, :current)
  def check, do: GenServer.call(__MODULE__, :check)
  def install, do: GenServer.call(__MODULE__, :install)
  def dismiss, do: GenServer.call(__MODULE__, :dismiss)

  @doc "Selects a newer release that has the package and checksum assets we need."
  def select_release(%{"tag_name" => tag, "assets" => assets}, current_version, format)
      when is_list(assets) and format in [:deb, :rpm] do
    with {:ok, version} <- parse_version(tag),
         {:ok, current} <- parse_version(current_version),
         true <- version > current,
         name = "MDT_#{version_string(version)}.#{format}",
         %{"browser_download_url" => package_url} <- find_asset(assets, name),
         %{"browser_download_url" => sums_url} <- find_asset(assets, "SHA256SUMS"),
         true <- release_url?(package_url, name),
         true <- release_url?(sums_url, "SHA256SUMS") do
      {:ok,
       %{
         version: version_string(version),
         name: name,
         package_url: package_url,
         sums_url: sums_url,
         format: format
       }}
    else
      _ -> :none
    end
  end

  def select_release(_release, _current_version, _format), do: :none

  @doc "Finds the exact SHA-256 entry for a package in a release checksum file."
  def checksum(contents, name) do
    contents
    |> String.split("\n")
    |> Enum.find_value(:error, fn line ->
      case String.split(line, ~r/\s+/, parts: 2, trim: true) do
        [hash, filename] ->
          if String.trim_leading(filename, "./") == name and
               String.match?(hash, ~r/\A[0-9a-fA-F]{64}\z/),
             do: {:ok, String.downcase(hash)}

        _ ->
          nil
      end
    end)
  end

  @impl true
  def init(_) do
    {:ok, %{status: :idle, release: nil, message: nil, task: nil}}
  end

  @impl true
  def handle_call(:current, _from, state), do: {:reply, public_state(state), state}

  def handle_call(:check, _from, %{status: status} = state)
      when status in [:checking, :installing],
      do: {:reply, {:error, :busy}, state}

  def handle_call(:check, _from, state) do
    if enabled?() do
      task =
        Task.Supervisor.async_nolink(MDTClient.HttpClient.TaskSupervisor, fn ->
          {:check, check_release()}
        end)

      state = publish(%{state | status: :checking, release: nil, message: nil, task: task.ref})
      {:reply, :ok, state}
    else
      state =
        publish(%{
          state
          | status: :error,
            release: nil,
            message: "Update checks are available in the installed desktop app."
        })

      {:reply, {:error, :desktop_only}, state}
    end
  end

  def handle_call(:install, _from, %{status: :available, release: release} = state) do
    task =
      Task.Supervisor.async_nolink(MDTClient.HttpClient.TaskSupervisor, fn ->
        {:install, install_release(release)}
      end)

    state = publish(%{state | status: :installing, message: nil, task: task.ref})
    {:reply, :ok, state}
  end

  def handle_call(:install, _from, state), do: {:reply, {:error, :unavailable}, state}

  def handle_call(:dismiss, _from, %{status: status} = state)
      when status in [:available, :current, :error] do
    {:reply, :ok, publish(%{state | status: :idle, release: nil, message: nil})}
  end

  def handle_call(:dismiss, _from, state), do: {:reply, :ok, state}

  @impl true
  def handle_info({ref, {:check, {:ok, release}}}, %{task: ref} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, publish(%{state | status: :available, release: release, task: nil})}
  end

  def handle_info({ref, {:check, :current}}, %{task: ref} = state) do
    Process.demonitor(ref, [:flush])

    {:noreply,
     publish(%{
       state
       | status: :current,
         message: "Version #{current_version()} is the latest.",
         task: nil
     })}
  end

  def handle_info({ref, {:check, {:error, reason}}}, %{task: ref} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, publish(%{state | status: :error, message: reason, task: nil})}
  end

  def handle_info({ref, {:install, :ok}}, %{task: ref} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, publish(%{state | status: :installed, task: nil})}
  end

  def handle_info({ref, {:install, {:error, reason}}}, %{task: ref} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, publish(%{state | status: :available, message: reason, task: nil})}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: ref} = state) do
    Logger.warning("MDT update task stopped: #{inspect(reason)}")
    status = if state.status == :installing, do: :available, else: :error

    message =
      if status == :available,
        do: "The update could not be installed. Please try again.",
        else: "Could not check for updates. Please try again."

    {:noreply, publish(%{state | status: status, message: message, task: nil})}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp check_release do
    with format when format in [:deb, :rpm] <- package_format(),
         {:ok, %Req.Response{status: 200, body: release}} <-
           Req.get(@release_url, @request_options) do
      case select_release(release, current_version(), format) do
        {:ok, selected} ->
          {:ok, selected}

        :none ->
          case compare_release(release) do
            :newer -> {:error, "The latest release does not have an installable package yet."}
            :current -> :current
            :invalid -> {:error, "Could not read the latest release version."}
          end
      end
    else
      nil ->
        {:error, "Updates require an installed x86-64 Debian or Fedora package."}

      other ->
        Logger.info("MDT release check unavailable: #{inspect(other)}")
        {:error, "Could not check for updates. Please try again."}
    end
  end

  defp compare_release(%{"tag_name" => tag}) do
    with {:ok, latest} <- parse_version(tag),
         {:ok, current} <- parse_version(current_version()) do
      if latest > current, do: :newer, else: :current
    else
      _ -> :invalid
    end
  end

  defp compare_release(_), do: :invalid

  defp install_release(release) do
    token = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
    dir = Path.join(System.tmp_dir!(), "mdt-update-#{token}")
    path = Path.join(dir, release.name)

    try do
      with :ok <- File.mkdir(dir),
           :ok <- File.chmod(dir, 0o700),
           {:ok, %Req.Response{status: 200, body: sums}} <-
             Req.get(release.sums_url, @request_options),
           {:ok, expected} <- checksum(sums, release.name),
           {:ok, %Req.Response{status: 200}} <-
             Req.get(
               release.package_url,
               Keyword.merge(@request_options,
                 into: File.stream!(path),
                 receive_timeout: 120_000
               )
             ),
           {:ok, actual} <- sha256(path),
           true <- actual == expected,
           :ok <- install_package(release.format, path) do
        :ok
      else
        false -> {:error, "The downloaded package did not match its release checksum."}
        :error -> {:error, "The release has no valid checksum for this package."}
        {:error, reason} -> {:error, error_message(reason)}
        _ -> {:error, "The update could not be downloaded. Please try again."}
      end
    after
      File.rm_rf(dir)
    end
  end

  defp install_package(format, path) do
    manager = if format == :deb, do: "apt-get", else: "dnf"

    with executable when is_binary(executable) <- System.find_executable(manager),
         pkexec when is_binary(pkexec) <- System.find_executable("pkexec"),
         {_output, 0} <-
           System.cmd(pkexec, [executable, "install", "-y", path], stderr_to_stdout: true) do
      :ok
    else
      nil ->
        {:error, "The system package installer is unavailable."}

      {output, _exit_code} ->
        Logger.warning("MDT package install failed: #{String.slice(output, -2000, 2000)}")

        {:error,
         "The system did not install the update. Check the authentication prompt and try again."}
    end
  end

  defp sha256(path) do
    hash =
      path
      |> File.stream!([], 1024 * 1024)
      |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
      |> :crypto.hash_final()
      |> Base.encode16(case: :lower)

    {:ok, hash}
  end

  defp find_asset(assets, name), do: Enum.find(assets, &(&1["name"] == name))

  defp release_url?(url, name) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: "github.com", path: path} ->
        String.starts_with?(path, "/oliveigah/mdt_client/releases/download/") and
          String.ends_with?(path, "/#{name}")

      _ ->
        false
    end
  end

  defp release_url?(_, _), do: false

  defp parse_version(version) when is_binary(version) do
    case Regex.run(~r/\Av?(\d+)\.(\d+)\.(\d+)\z/, version) do
      [_, major, minor, patch] ->
        {:ok, {String.to_integer(major), String.to_integer(minor), String.to_integer(patch)}}

      _ ->
        :error
    end
  end

  defp parse_version(_), do: :error
  defp version_string({major, minor, patch}), do: "#{major}.#{minor}.#{patch}"
  defp current_version, do: :mdt_client |> Application.spec(:vsn) |> to_string()

  defp enabled?, do: System.get_env("MDT_DESKTOP_BUILD") == "true"

  defp package_format do
    arch = :erlang.system_info(:system_architecture) |> to_string()

    cond do
      not String.starts_with?(arch, "x86_64") -> nil
      installed?("dpkg-query", ["-W", "-f=${Status}", "mdt"], "install ok installed") -> :deb
      installed?("rpm", ["-q", "mdt"], nil) -> :rpm
      true -> nil
    end
  end

  defp installed?(command, args, expected) do
    case System.find_executable(command) do
      nil ->
        false

      executable ->
        case System.cmd(executable, args, stderr_to_stdout: true) do
          {output, 0} -> expected == nil or String.trim(output) == expected
          _ -> false
        end
    end
  end

  defp public_state(state), do: Map.take(state, [:status, :release, :message])

  defp publish(state) do
    Phoenix.PubSub.broadcast(MDTClient.PubSub, @topic, {:mdt_update, public_state(state)})
    state
  end

  defp error_message(reason) when is_binary(reason), do: reason
  defp error_message(_), do: "The update could not be installed. Please try again."
end
