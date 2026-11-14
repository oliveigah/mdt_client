defmodule MDTClient.Sandbox.Discovery do
  @moduledoc """
  The git repositories in your shared folders: each one is a project
  (`MDTClient.Sandbox.Project`). Shared folders are the one place that
  decides what the VM sees, so a repository outside them is never one.

  The scan reads the filesystem only, and is bounded:

    * a folder with a `.git` folder is a repository, and nothing inside it
      is looked at (submodules and nested repositories are left out for
      now);
    * a folder with a `.git` file is a linked worktree or a submodule of
      another repository, and is skipped;
    * hidden folders and the usual build and dependency folders
      (`node_modules`, `deps`, `_build`, `target`, …) are skipped, and so
      are symlinks;
    * at most 4 levels below the shared folder, and at most 20,000
      folders in all.
  """

  alias MDTClient.Sandbox.Share

  @depth 4
  @max_folders 20_000
  @skipped ~w(node_modules deps _build target vendor dist build __pycache__ venv)

  @type repository :: %{path: Path.t(), share: Share.t(), branch: String.t() | nil}

  @doc "The repositories in `shares`, each with the share it is in and the branch it has checked out."
  @spec repositories([Share.t()]) :: [repository()]
  def repositories(shares) do
    {found, _budget} =
      Enum.flat_map_reduce(shares, @max_folders, fn share, budget ->
        {found, budget} = walk([{share.path, 0}], budget, [])
        {Enum.map(Enum.reverse(found), &%{path: &1, share: share, branch: branch(&1)}), budget}
      end)

    Enum.sort_by(found, & &1.path)
  end

  defp walk([], budget, found), do: {found, budget}
  defp walk(_queue, budget, found) when budget <= 0, do: {found, budget}

  defp walk([{dir, depth} | rest], budget, found) do
    case File.lstat(Path.join(dir, ".git")) do
      {:ok, %File.Stat{type: :directory}} ->
        walk(rest, budget - 1, [dir | found])

      {:ok, _file} ->
        # A linked worktree or a submodule: another repository's.
        walk(rest, budget - 1, found)

      {:error, _} when depth >= @depth ->
        walk(rest, budget - 1, found)

      {:error, _} ->
        walk(rest ++ children(dir, depth + 1), budget - 1, found)
    end
  end

  defp children(dir, depth) do
    case File.ls(dir) do
      {:ok, names} ->
        for name <- Enum.sort(names),
            not String.starts_with?(name, "."),
            name not in @skipped,
            path = Path.join(dir, name),
            match?({:ok, %File.Stat{type: :directory}}, File.lstat(path)),
            do: {path, depth}

      {:error, _} ->
        []
    end
  end

  # Read from `.git/HEAD`, without running git: nil when detached.
  defp branch(path) do
    case File.read(Path.join([path, ".git", "HEAD"])) do
      {:ok, "ref: refs/heads/" <> rest} -> String.trim(rest)
      _ -> nil
    end
  end
end
