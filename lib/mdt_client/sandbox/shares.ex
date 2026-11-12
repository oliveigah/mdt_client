defmodule MDTClient.Sandbox.Shares do
  @moduledoc """
  Decides whether a host folder may be shared with the VM.

  Three rules, each from something the VM could otherwise do:

    * **No credential folders.** Sharing `~/.ssh`, `~/.optmem`, MDT's own data
      folder and the like, or any folder holding one of them, hands the VM
      what it must never hold.
    * **No overlaps.** Root in the VM can unmount a read-only folder sitting
      inside a read-write one and write to the host folder underneath; the
      checks of 2026-11-11 did exactly that.
    * **Real folders only.** The path is resolved through every symlink
      before it is judged, so a link inside a project cannot smuggle in a
      folder the rules refuse.

  Pure apart from reading the filesystem to resolve the path.
  """

  alias MDTClient.Sandbox.Share

  @max_links 40

  # Relative to the home folder: what holds credentials, keys or the
  # memory of host agents.
  @refused_in_home [
    {".ssh", "SSH keys"},
    {".gnupg", "GPG keys"},
    {".optmem", "your host agents' memory"},
    {".microsandbox", "microsandbox's own state"},
    {".aws", "AWS credentials"},
    {".kube", "Kubernetes credentials"},
    {".docker", "Docker credentials"},
    {".config/gcloud", "Google Cloud credentials"},
    {".config/gh", "the GitHub CLI's login"},
    {".hex", "your Hex login"},
    {".local/share/keyrings", "the desktop keyring"},
    {".password-store", "your password store"}
  ]

  @type reason ::
          :blank
          | :not_absolute
          | :missing
          | :not_a_folder
          | :loop
          | :home
          | :root
          | {:refused, String.t(), String.t()}
          | {:overlaps, String.t()}
          | :duplicate

  @doc """
  Checks `path` against the folders already shared.

  ## Options

    * `:home` - the home folder, defaults to the user's
    * `:data_dir` - MDT's data folder, defaults to `MDTClient.Accounts.root/0`

  Returns the resolved share, or why it is refused.
  """
  @spec validate(String.t(), :rw | :ro, [Share.t()], keyword()) ::
          {:ok, Share.t()} | {:error, reason()}
  def validate(path, mode, shares, opts \\ []) when mode in [:rw, :ro] do
    home = opts |> Keyword.get_lazy(:home, &System.user_home!/0) |> realpath_or_self()

    data_dir =
      opts |> Keyword.get_lazy(:data_dir, &MDTClient.Accounts.root/0) |> realpath_or_self()

    with {:ok, path} <- normalize(path, home),
         {:ok, real} <- realpath(path),
         :ok <- folder(real),
         :ok <- not_root_or_home(real, home),
         :ok <- not_refused(real, home, data_dir),
         :ok <- no_overlap(real, shares) do
      {:ok, %Share{path: real, mode: mode}}
    end
  end

  @doc "A sentence explaining a refusal, for the settings page."
  @spec explain(reason()) :: String.t()
  def explain(:blank), do: "Enter a folder to share."
  def explain(:not_absolute), do: "Use a full path, starting with / or ~."
  def explain(:missing), do: "That folder does not exist."
  def explain(:not_a_folder), do: "That is a file, not a folder."
  def explain(:loop), do: "That path loops through symlinks."
  def explain(:root), do: "The whole filesystem cannot be shared."

  def explain(:home),
    do: "Your home folder holds your credentials. Share the project folders inside it instead."

  def explain({:refused, folder, what}),
    do: "This would share #{folder}, which holds #{what}."

  def explain({:overlaps, other}),
    do:
      "Overlaps #{other}, which is already shared. A folder inside another can be unmounted from the VM, so pick one or the other."

  def explain(:duplicate), do: "That folder is already shared."

  defp normalize(path, home) do
    case String.trim(path) do
      "" -> {:error, :blank}
      "~" -> {:ok, home}
      "~/" <> rest -> {:ok, Path.join(home, rest) |> Path.expand()}
      "/" <> _ = absolute -> {:ok, Path.expand(absolute)}
      _relative -> {:error, :not_absolute}
    end
  end

  defp folder(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :directory}} -> :ok
      {:ok, _other} -> {:error, :not_a_folder}
      {:error, _} -> {:error, :missing}
    end
  end

  defp not_root_or_home("/", _home), do: {:error, :root}
  defp not_root_or_home(home, home), do: {:error, :home}
  defp not_root_or_home(_path, _home), do: :ok

  defp not_refused(path, home, data_dir) do
    refused =
      [
        {data_dir, "MDT's own data"}
        | Enum.map(@refused_in_home, fn {rel, what} -> {Path.join(home, rel), what} end)
      ]

    Enum.find_value(refused, :ok, fn {folder, what} ->
      if within?(path, folder) or within?(folder, path),
        do: {:error, {:refused, folder, what}}
    end)
  end

  defp no_overlap(path, shares) do
    Enum.find_value(shares, :ok, fn %Share{path: other} ->
      cond do
        other == path -> {:error, :duplicate}
        within?(path, other) or within?(other, path) -> {:error, {:overlaps, other}}
        true -> nil
      end
    end)
  end

  # Whether `path` is `folder` or somewhere inside it.
  defp within?(path, folder), do: path == folder or String.starts_with?(path, folder <> "/")

  defp realpath_or_self(path) do
    case realpath(Path.expand(path)) do
      {:ok, real} -> real
      {:error, _} -> Path.expand(path)
    end
  end

  # Resolves every symlink along `path`, as the kernel would when mounting it.
  defp realpath(path), do: resolve(Path.split(path), "/", 0)

  defp resolve(_parts, _at, links) when links > @max_links, do: {:error, :loop}
  defp resolve([], at, _links), do: {:ok, at}
  defp resolve(["/" | rest], _at, links), do: resolve(rest, "/", links)
  defp resolve(["." | rest], at, links), do: resolve(rest, at, links)
  defp resolve([".." | rest], at, links), do: resolve(rest, Path.dirname(at), links)

  defp resolve([part | rest], at, links) do
    next = Path.join(at, part)

    case File.read_link(next) do
      {:ok, target} ->
        target_parts = Path.split(target)
        start = if Path.type(target) == :absolute, do: "/", else: at
        resolve(target_parts ++ rest, start, links + 1)

      {:error, _not_a_link} ->
        resolve(rest, next, links)
    end
  end
end
