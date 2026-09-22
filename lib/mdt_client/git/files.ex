defmodule MDTClient.Git.Files do
  @moduledoc """
  The read-only working-tree boundary of the Git backend.

  `status/1` is the only entry point: it lists the repository paths Git
  considers changed as `MDTClient.Git.FileChange` structs, which is what the
  action panel needs to build a selection for `MDTClient.Git.Core.stage/2`,
  `unstage/2`, and `stash/3`. Diffs, file contents, editing, and discard are
  deliberately not part of it, so branch and graph refreshes never pay for
  larger payloads.

  The module shares `MDTClient.Git.Repository` handles and the command runner
  with `MDTClient.Git.Core`, so the SSH credentials and safety guarantees of a tab
  apply here too.
  """

  alias MDTClient.Git.Command
  alias MDTClient.Git.Error
  alias MDTClient.Git.FileChange
  alias MDTClient.Git.Repository

  # Porcelain v2 reports the index and working-tree side of every path with two
  # single letter codes. A dot means "no change on this side".
  @states %{
    "." => nil,
    "M" => :modified,
    "T" => :type_changed,
    "A" => :added,
    "D" => :deleted,
    "R" => :renamed,
    "C" => :copied
  }

  @doc """
  Lists the changed repository paths, sorted by path.

  Reads `git status --porcelain=v2 -z`, whose records are NUL terminated, so
  file names containing spaces, quotes, or newlines survive unescaped.
  """
  @spec status(Repository.t()) :: {:ok, [FileChange.t()]} | {:error, Error.t()}
  def status(%Repository{} = repository) do
    with {:ok, output} <-
           Command.run(repository, [
             "status",
             "--porcelain=v2",
             "--untracked-files=all",
             "-z"
           ]) do
      parse(output)
    end
  end

  defp parse(output) do
    case collect(String.split(output, <<0>>), []) do
      {:ok, changes} -> {:ok, Enum.sort_by(changes, & &1.path)}
      {:error, error} -> {:error, error}
    end
  end

  # The records are consumed one at a time because a rename spans two of them:
  # the new path, then the original path.
  defp collect([], acc), do: {:ok, acc}
  defp collect(["" | rest], acc), do: collect(rest, acc)
  defp collect(["# " <> _header | rest], acc), do: collect(rest, acc)
  defp collect(["! " <> _ignored | rest], acc), do: collect(rest, acc)

  defp collect(["? " <> path | rest], acc) when path != "" do
    change = %FileChange{path: path, unstaged: :untracked, untracked?: true}
    collect(rest, [change | acc])
  end

  defp collect(["1 " <> entry | rest], acc) do
    continue(entry, rest, acc, &ordinary/1)
  end

  defp collect(["2 " <> entry, original | rest], acc) when original != "" do
    continue(entry, rest, acc, &renamed(&1, original))
  end

  defp collect(["u " <> entry | rest], acc) do
    continue(entry, rest, acc, &unmerged/1)
  end

  defp collect([record | _rest], _acc), do: invalid(record)

  defp continue(entry, rest, acc, parser) do
    case parser.(entry) do
      {:ok, change} -> collect(rest, [change | acc])
      {:error, error} -> {:error, error}
    end
  end

  # <XY> <sub> <mH> <mI> <mW> <hH> <hI> <path>
  defp ordinary(entry) do
    case String.split(entry, " ", parts: 8) do
      [codes, _sub, _mode_head, _mode_index, _mode_worktree, _hash_head, _hash_index, path]
      when path != "" ->
        tracked(codes, path, nil)

      _invalid ->
        invalid(entry)
    end
  end

  # <XY> <sub> <mH> <mI> <mW> <hH> <hI> <score> <path>
  defp renamed(entry, original) do
    case String.split(entry, " ", parts: 9) do
      [
        codes,
        _sub,
        _mode_head,
        _mode_index,
        _mode_worktree,
        _hash_head,
        _hash_index,
        _score,
        path
      ]
      when path != "" ->
        tracked(codes, path, original)

      _invalid ->
        invalid(entry)
    end
  end

  # <XY> <sub> <m1> <m2> <m3> <mW> <h1> <h2> <h3> <path>
  defp unmerged(entry) do
    case String.split(entry, " ", parts: 10) do
      [_codes, _sub, _m1, _m2, _m3, _mode_worktree, _h1, _h2, _h3, path] when path != "" ->
        {:ok, %FileChange{path: path, unstaged: :conflicted, conflicted?: true}}

      _invalid ->
        invalid(entry)
    end
  end

  defp tracked(<<index::binary-size(1), worktree::binary-size(1)>>, path, original) do
    with {:ok, staged} <- Map.fetch(@states, index),
         {:ok, unstaged} <- Map.fetch(@states, worktree) do
      {:ok,
       %FileChange{
         path: path,
         original_path: original,
         staged: staged,
         unstaged: unstaged
       }}
    else
      :error -> invalid(path)
    end
  end

  defp tracked(_codes, path, _original), do: invalid(path)

  defp invalid(record) do
    {:error,
     Error.new(:invalid_output, "Git returned an unreadable status record: #{inspect(record)}")}
  end
end
