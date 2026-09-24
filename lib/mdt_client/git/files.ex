defmodule MDTClient.Git.Files do
  @moduledoc """
  The read-only working-tree boundary of the Git backend.

  `status/1` lists the repository paths Git considers changed as
  `MDTClient.Git.FileChange` structs, which is what the action panel needs to
  build a selection for `MDTClient.Git.Core.stage/2`, `unstage/2`, `discard/2`,
  and `stash/3`. `diff/3` reads the unified diff of a single path on request,
  so branch and graph refreshes never pay for diff payloads.

  Editing files is deliberately still absent.

  The module shares `MDTClient.Git.Repository` handles and the command runner
  with `MDTClient.Git.Core`, so the SSH credentials and safety guarantees of a tab
  apply here too.
  """

  alias MDTClient.Git.Command
  alias MDTClient.Git.DiffHunk
  alias MDTClient.Git.DiffLine
  alias MDTClient.Git.Error
  alias MDTClient.Git.FileChange
  alias MDTClient.Git.FileDiff
  alias MDTClient.Git.Repository

  @default_line_limit 2_000

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

  @doc """
  Lists the paths one commit changed, newest side first.

  The result reuses `MDTClient.Git.FileChange` so a commit reads like any other
  set of changes: the kind of change sits in `staged`, because everything in a
  commit is already recorded. A merge is compared against its first parent,
  which is what the merge brought onto the branch.
  """
  @spec commit_status(Repository.t(), String.t()) ::
          {:ok, [FileChange.t()]} | {:error, Error.t()}
  def commit_status(%Repository{} = repository, revision) do
    with {:ok, revision} <- revision_argument(revision),
         {:ok, output} <-
           Command.run(repository, [
             "diff-tree",
             "--no-commit-id",
             "--name-status",
             "--find-renames",
             "--root",
             "-r",
             "-z",
             "--diff-merges=first-parent",
             revision
           ]) do
      collect_commit_changes(String.split(output, <<0>>), [])
    end
  end

  defp collect_commit_changes([], acc), do: {:ok, Enum.sort_by(acc, & &1.path)}
  defp collect_commit_changes([""], acc), do: collect_commit_changes([], acc)
  defp collect_commit_changes(["" | rest], acc), do: collect_commit_changes(rest, acc)

  # A rename or a copy names both sides, so it spans three records instead of two.
  defp collect_commit_changes(
         [<<letter::binary-size(1), _score::binary>> = code, original, path | rest],
         acc
       )
       when letter in ["R", "C"] and path != "" do
    case Map.fetch(@states, letter) do
      {:ok, state} ->
        change = %FileChange{path: path, original_path: original, staged: state}
        collect_commit_changes(rest, [change | acc])

      :error ->
        invalid(code)
    end
  end

  defp collect_commit_changes([code, path | rest], acc) when path != "" do
    case Map.fetch(@states, code) do
      {:ok, state} -> collect_commit_changes(rest, [%FileChange{path: path, staged: state} | acc])
      :error -> invalid(code)
    end
  end

  defp collect_commit_changes([record | _rest], _acc), do: invalid(record)

  defp revision_argument(revision) when is_binary(revision) and revision != "" do
    if String.starts_with?(revision, "-") or String.contains?(revision, <<0>>) do
      {:error, Error.new(:invalid_argument, "Invalid revision")}
    else
      {:ok, revision}
    end
  end

  defp revision_argument(_revision),
    do: {:error, Error.new(:invalid_argument, "Revision must be a non-empty string")}

  @doc """
  Returns the unified diff of one repository path.

  `:side` selects which half of the change to read: `:unstaged` (the default)
  compares the working tree against the index, `:staged` compares the index
  against HEAD. Pass `untracked: true` for a path Git does not track yet, whose
  whole content reads as added. `:lines` caps how much is parsed, so opening a
  generated file cannot flood the caller.
  """
  @spec diff(Repository.t(), Path.t(), keyword()) :: {:ok, FileDiff.t()} | {:error, Error.t()}
  def diff(%Repository{} = repository, path, opts \\ []) do
    with {:ok, side} <- diff_side(Keyword.get(opts, :side, :unstaged)),
         {:ok, limit} <- line_limit(Keyword.get(opts, :lines, @default_line_limit)),
         {:ok, relative} <- repository_path(repository, path),
         {:ok, output} <- read(repository, relative, side, opts) do
      {:ok, parse_diff(output, path, side, limit)}
    end
  end

  defp read(repository, relative, side, opts) do
    case Keyword.get(opts, :commit) do
      nil -> read_diff(repository, side, relative, Keyword.get(opts, :untracked, false))
      revision -> read_commit_diff(repository, revision, relative)
    end
  end

  defp read_commit_diff(repository, revision, relative) do
    with {:ok, revision} <- revision_argument(revision) do
      Command.run(repository, [
        "show",
        "--no-color",
        "--no-ext-diff",
        "--format=",
        "--find-renames",
        "--diff-merges=first-parent",
        revision,
        "--",
        pathspec(relative)
      ])
    end
  end

  defp diff_side(side) when side in [:staged, :unstaged, :commit], do: {:ok, side}

  defp diff_side(_side),
    do: {:error, Error.new(:invalid_argument, "Diff side must be :staged, :unstaged, or :commit")}

  defp line_limit(lines) when is_integer(lines) and lines > 0, do: {:ok, lines}

  defp line_limit(_lines),
    do: {:error, Error.new(:invalid_argument, "Line limit must be a positive integer")}

  # An untracked file has nothing to compare against inside the repository, so
  # Git reads it against an empty file instead. That form reports "differences
  # found" with exit status 1, which is a result rather than a failure here.
  defp read_diff(repository, :unstaged, relative, true) do
    args = ["diff", "--no-color", "--no-ext-diff", "--no-index", "--", "/dev/null", relative]

    case Command.capture(repository, args) do
      {:system_error, error} -> {:error, error}
      {output, status} when status in [0, 1] -> {:ok, output}
      {output, status} -> {:error, Error.command(args, status, output)}
    end
  end

  defp read_diff(_repository, :staged, _relative, true) do
    {:ok, ""}
  end

  defp read_diff(repository, side, relative, _untracked?) do
    staged = if side == :staged, do: ["--cached"], else: []
    args = ["diff", "--no-color", "--no-ext-diff"] ++ staged ++ ["--", pathspec(relative)]

    Command.run(repository, args)
  end

  defp pathspec(relative), do: ":(top,literal)" <> relative

  defp repository_path(repository, path) when is_binary(path) and path != "" do
    relative = Path.relative_to(Path.expand(path, repository.path), repository.path)

    if relative == "." or Path.type(relative) == :absolute or
         String.starts_with?(relative, "../") do
      {:error, Error.new(:invalid_argument, "File path is outside the repository")}
    else
      {:ok, relative}
    end
  end

  defp repository_path(_repository, _path),
    do: {:error, Error.new(:invalid_argument, "File path must be a non-empty string")}

  defp parse_diff(output, path, side, limit) do
    state =
      output
      |> String.split("\n")
      |> Enum.reduce(
        %{hunks: [], hunk: nil, old: 0, new: 0, count: 0, binary?: false, truncated?: false},
        &diff_line/2
      )
      |> close_hunk()

    %FileDiff{
      path: path,
      side: side,
      hunks: Enum.reverse(state.hunks),
      binary?: state.binary?,
      truncated?: state.truncated?
    }
    |> cap(limit)
  end

  defp diff_line(_line, %{truncated?: true} = state), do: state

  defp diff_line("@@" <> _rest = line, state) do
    state = close_hunk(state)

    case Regex.run(~r/^@@+ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@+ ?(.*)$/, line,
           capture: :all_but_first
         ) do
      [old, new, heading] ->
        old = String.to_integer(old)
        new = String.to_integer(new)

        %{
          state
          | hunk: %DiffHunk{
              header: line,
              heading: if(heading == "", do: nil, else: heading),
              old_start: old,
              new_start: new,
              lines: []
            },
            old: old,
            new: new
        }

      _unreadable ->
        %{state | hunk: nil}
    end
  end

  defp diff_line("Binary files " <> _rest, state), do: %{state | binary?: true}
  defp diff_line("GIT binary patch" <> _rest, state), do: %{state | binary?: true}
  defp diff_line(_line, %{hunk: nil} = state), do: state
  defp diff_line("\\" <> _no_newline, state), do: state

  defp diff_line("+" <> text, state) do
    add_line(state, %DiffLine{kind: :added, text: text, new_line: state.new}, 0, 1)
  end

  defp diff_line("-" <> text, state) do
    add_line(state, %DiffLine{kind: :removed, text: text, old_line: state.old}, 1, 0)
  end

  defp diff_line(" " <> text, state) do
    line = %DiffLine{kind: :context, text: text, old_line: state.old, new_line: state.new}
    add_line(state, line, 1, 1)
  end

  defp diff_line("", state), do: state
  defp diff_line(_line, state), do: state

  defp add_line(state, line, old_step, new_step) do
    %{
      state
      | hunk: %{state.hunk | lines: [line | state.hunk.lines]},
        old: state.old + old_step,
        new: state.new + new_step,
        count: state.count + 1
    }
  end

  defp close_hunk(%{hunk: nil} = state), do: state

  defp close_hunk(%{hunk: hunk} = state) do
    hunk = %{hunk | lines: Enum.reverse(hunk.lines)}
    %{state | hunks: [hunk | state.hunks], hunk: nil}
  end

  defp cap(%FileDiff{} = diff, limit) do
    {hunks, _kept} =
      Enum.reduce_while(diff.hunks, {[], 0}, fn hunk, {hunks, kept} ->
        room = limit - kept

        cond do
          room <= 0 -> {:halt, {hunks, kept}}
          length(hunk.lines) <= room -> {:cont, {[hunk | hunks], kept + length(hunk.lines)}}
          true -> {:halt, {[%{hunk | lines: Enum.take(hunk.lines, room)} | hunks], limit}}
        end
      end)

    hunks = Enum.reverse(hunks)
    %{diff | hunks: hunks, truncated?: hunks != diff.hunks}
  end
end
