defmodule MDTClient.Sandbox.PullTarget do
  @moduledoc """
  Which repository of yours a pull request is for: the git repository
  itself is the project, and nothing is set up beforehand.

  The agent names a folder on your machine (`mdt pr --repo PATH`), or MDT
  works it out from the repository in the VM, first match wins:

    1. a remote of it that is a path on your machine, as when it was
       cloned from a shared folder;
    2. its own path, when you have a repository at the same path;
    3. a repository you know that has one of its remotes: one open in the
       Git tool, or one an earlier pull request was for.

  Whatever names it, the folder is checked here: it must be in a git
  repository with a commit, and that repository must be one the VM can't
  write. A `.git` in a read-write shared folder could hold a hook or a
  `core.fsmonitor` line, and MDT runs git there; so could MDT's own data
  folder, or any other folder `MDTClient.Sandbox.Shares` refuses to share.
  """

  alias MDTClient.Sandbox.{HostGit, Share, Shares}

  @type error ::
          :no_target
          | {:not_a_repository, String.t()}
          | {:no_commit, String.t()}
          | {:writable, String.t()}
          | {:refused, String.t(), String.t()}

  @typedoc "What MDT read of the repository in the VM."
  @type vm :: %{top: String.t(), remotes: [String.t()]}

  @doc """
  The top folder of the repository the pull request is for.

  `claim` is the folder the agent named, or nil. `known` lists repositories
  you know (top folders). Options: `:shares`, `:home`, `:data_dir`.
  """
  @spec resolve(String.t() | nil, vm(), [Path.t()], keyword()) ::
          {:ok, Path.t()} | {:error, error()}
  def resolve(claim, vm, known, opts \\ [])

  def resolve(claim, _vm, _known, opts) when is_binary(claim) and claim != "" do
    check(claim, opts)
  end

  def resolve(_claim, vm, known, opts) do
    local = for url <- vm.remotes, path = local_path(url), do: path

    found =
      Enum.find_value(local ++ [vm.top], &ok(check(&1, opts))) ||
        Enum.find_value(Enum.uniq(known), fn repo ->
          if shares_remote?(repo, vm.remotes), do: ok(check(repo, opts))
        end)

    if found, do: {:ok, found}, else: {:error, :no_target}
  end

  defp ok({:ok, repo}), do: repo
  defp ok(_), do: nil

  @doc """
  Checks the folder `path` on your machine: the top folder of its
  repository when that is one a pull request may be for.
  """
  @spec check(String.t(), keyword()) :: {:ok, Path.t()} | {:error, error()}
  def check(path, opts \\ []) do
    shares = Keyword.get(opts, :shares, [])
    path = path |> to_string() |> String.trim()
    shown = String.slice(path, 0, 300)

    with true <- String.starts_with?(path, ["/", "~/"]) || {:error, {:not_a_repository, shown}},
         {:ok, real} <- Shares.realpath(Path.expand(path)),
         true <- File.dir?(real) || {:error, {:not_a_repository, shown}},
         top when is_binary(top) <- HostGit.top(real) || {:error, {:not_a_repository, shown}},
         {:ok, top} <- Shares.realpath(top),
         paths = [top | git_dirs(top)],
         :ok <- not_writable(paths, shares),
         :ok <- not_refused(paths, opts),
         true <-
           HostGit.line(top, ["rev-parse", "--verify", "--quiet", "HEAD^{commit}"]) != nil ||
             {:error, {:no_commit, top}} do
      {:ok, top}
    else
      {:error, :loop} -> {:error, {:not_a_repository, shown}}
      {:error, reason} -> {:error, reason}
    end
  end

  # The repository's own folder and the one its worktrees share.
  defp git_dirs(top) do
    for flag <- ["--git-dir", "--git-common-dir"],
        dir = HostGit.line(top, ["rev-parse", "--path-format=absolute", flag]),
        is_binary(dir),
        {:ok, real} <- [Shares.realpath(dir)],
        uniq: true,
        do: real
  end

  defp not_writable(paths, shares) do
    Enum.find_value(shares, :ok, fn
      %Share{mode: :rw, path: shared} ->
        if Enum.any?(paths, &(Shares.within?(&1, shared) or Shares.within?(shared, &1))),
          do: {:error, {:writable, shared}}

      _read_only ->
        nil
    end)
  end

  defp not_refused(paths, opts) do
    Enum.find_value(paths, :ok, fn path ->
      case Shares.refused(path, Keyword.take(opts, [:home, :data_dir])) do
        nil -> nil
        {folder, what} -> {:error, {:refused, folder, what}}
      end
    end)
  end

  # A remote that is a folder of this machine: `/path`, or `file:///path`.
  defp local_path("file://" <> path), do: local_path(path)
  defp local_path("/" <> _ = path), do: path
  defp local_path(_url), do: nil

  defp shares_remote?(repo, vm_remotes) do
    wanted = vm_remotes |> Enum.map(&normalize/1) |> Enum.reject(&is_nil/1) |> MapSet.new()

    MapSet.size(wanted) > 0 and
      case HostGit.run(repo, ["remote", "-v"]) do
        {:ok, output} ->
          output
          |> String.split("\n", trim: true)
          |> Enum.any?(fn line ->
            case String.split(line, ~r/\s+/, trim: true) do
              [_name, url | _] -> MapSet.member?(wanted, normalize(url))
              _ -> false
            end
          end)

        {:error, _} ->
          false
      end
  end

  @doc """
  A remote's address in one form for comparing: host and path, lowercase
  host, no scheme, user, port or `.git`. Local paths are left out (nil).

      iex> MDTClient.Sandbox.PullTarget.normalize("git@github.com:me/app.git")
      "github.com/me/app"

      iex> MDTClient.Sandbox.PullTarget.normalize("https://token@GitHub.com/me/app/")
      "github.com/me/app"
  """
  @spec normalize(String.t()) :: String.t() | nil
  def normalize(url) do
    url = String.trim(url)

    rest =
      cond do
        url =~ ~r{^[a-z][a-z0-9+.-]*://}i -> url |> String.split("://", parts: 2) |> List.last()
        url =~ ~r{^[^/@]+@[^/:]+:} -> url
        true -> nil
      end

    case rest do
      nil ->
        nil

      rest ->
        rest = rest |> String.split("@", parts: 2) |> List.last()

        case String.split(rest, ~r{[:/]}, parts: 2) do
          [host, path] ->
            host = host |> String.downcase()
            # A port after the host (ssh://host:22/path) is not part of the path.
            path = Regex.replace(~r{^\d+/}, path, "")
            path = path |> String.trim("/") |> String.replace_suffix(".git", "")
            if path == "", do: nil, else: "#{host}/#{path}"

          _ ->
            nil
        end
    end
  end

  @doc "Why a folder is not one a pull request may be for, in words for the agent and for you."
  @spec explain(error()) :: String.t()
  def explain(:no_target),
    do:
      "MDT can't tell which repository on the user's machine this is for. " <>
        "Name it: mdt pr --repo /path/on/their/machine (ask the user for the path when you don't know it)."

  def explain({:not_a_repository, path}),
    do: "#{path} is not a folder in a git repository on the user's machine."

  def explain({:no_commit, path}), do: "The repository at #{path} has no commit yet."

  def explain({:writable, shared}),
    do:
      "That repository is in #{shared}, which the VM can write. MDT won't run git there for a pull request."

  def explain({:refused, folder, what}),
    do:
      "That repository is in #{folder}, which holds #{what}. MDT won't use it for a pull request."
end
