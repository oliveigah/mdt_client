defmodule MDTClient.Sandbox.Project do
  @moduledoc """
  A git repository of yours that has a copy in the VM, on its Work disk at
  `/work/<name>`. No folder is shared: your branches reach the copy by sync
  (`MDTClient.Sandbox.Sync`), and work comes back as handoffs
  (`MDTClient.Sandbox.Handoff`).

  `name` is the folder's name there, made from your folder's name. Agents
  work in worktrees beside it, under `/work/<name>.wt/`.
  """

  alias MDTClient.Sandbox.{Guest, HostGit, Shares}

  @enforce_keys [:name, :path]
  defstruct [:name, :path, :synced_at]

  @type t :: %__MODULE__{name: String.t(), path: Path.t(), synced_at: DateTime.t() | nil}

  @type error :: :not_a_folder | :not_a_repository | :not_its_top | :no_commit | :already_added

  @doc """
  The project for the repository at `path`, which must be the top folder of
  a git repository with at least one commit, and not one of `existing`.
  """
  @spec new(String.t(), [t()]) :: {:ok, t()} | {:error, error()}
  def new(path, existing) do
    path = path |> String.trim() |> Path.expand()

    with true <- File.dir?(path) || {:error, :not_a_folder},
         {:ok, real} <- Shares.realpath(path),
         top when is_binary(top) <- HostGit.top(real) || {:error, :not_a_repository},
         true <- top == real || {:error, :not_its_top},
         true <-
           HostGit.line(real, ["rev-parse", "--verify", "--quiet", "HEAD"]) != nil ||
             {:error, :no_commit},
         false <- Enum.any?(existing, &(&1.path == real)) && {:error, :already_added} do
      {:ok, %__MODULE__{name: name(Path.basename(real), existing), path: real}}
    else
      {:error, :loop} -> {:error, :not_a_folder}
      {:error, reason} -> {:error, reason}
    end
  end

  # Letters, digits, dot, dash and underscore: a folder name that needs no
  # quoting anywhere. Two folders with one name get a number.
  defp name(base, existing) do
    slug =
      base
      |> String.replace(~r/[^A-Za-z0-9._-]+/, "-")
      |> String.trim("-")
      |> String.trim_leading(".")
      |> then(&if(&1 == "", do: "project", else: &1))

    taken = MapSet.new(existing, & &1.name)

    Enum.find([slug | Enum.map(2..999, &"#{slug}-#{&1}")], &(not MapSet.member?(taken, &1)))
  end

  @doc "The copy's folder in the VM."
  @spec guest_path(t(), Guest.t()) :: Path.t()
  def guest_path(%__MODULE__{name: name}, guest), do: Path.join(guest.root, name)

  @doc "Where agents make their worktrees in the VM."
  @spec worktrees_path(t(), Guest.t()) :: Path.t()
  def worktrees_path(project, guest), do: guest_path(project, guest) <> ".wt"

  @doc "The project a folder in the VM belongs to: the copy itself, or a worktree beside it."
  @spec of([t()], Guest.t(), String.t()) :: t() | nil
  def of(projects, guest, folder) do
    Enum.find(projects, fn project ->
      copy = guest_path(project, guest)

      folder == copy or String.starts_with?(folder, copy <> "/") or
        String.starts_with?(folder, worktrees_path(project, guest) <> "/")
    end)
  end

  @doc "Why a folder can't be a project, in words."
  @spec explain(error()) :: String.t()
  def explain(:not_a_folder), do: "That folder does not exist."
  def explain(:not_a_repository), do: "That folder is not a git repository."
  def explain(:not_its_top), do: "Choose the repository's top folder, the one holding .git."
  def explain(:no_commit), do: "That repository has no commit yet."
  def explain(:already_added), do: "That repository is a project already."
end
