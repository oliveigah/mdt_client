defmodule MDTClient.Sandbox.Handoff do
  @moduledoc """
  Finished work an agent offers back: the branch of one agent worktree of a
  project (`MDTClient.Sandbox.Project`), offered to one of the project's
  target branches (`onto`), with a title and a description.

  An agent runs `mdt handoff` in its worktree, with everything committed and
  after catching up with the mirror (`git merge host`): a handoff whose
  branch doesn't merge cleanly with the target branch as it is now is
  refused. Its commits wait in MDT's store (`MDTClient.Sandbox.HandoffStore`),
  so nothing is written into your repository until you accept it
  (`MDTClient.Sandbox.Accept`). Running `mdt handoff` again on the same
  branch makes a new revision of the same handoff while it is open.

  `title`, `body`, `agent`, `thread` and the commit messages are the
  agent's words: claims. What MDT works out itself is in `facts/2`.
  """

  alias MDTClient.Git.{FileDiff, Files}
  alias MDTClient.Sandbox.{Guest, HandoffStore, HostGit, Shown}

  @enforce_keys [:id, :title, :project, :repo, :onto, :source, :head, :opened_at]
  defstruct [
    :id,
    :title,
    :agent,
    :thread,
    :thread_id,
    :project,
    :repo,
    :onto,
    :source,
    :head,
    :opened_at,
    :updated_at,
    :accepted,
    :base_commit,
    body: "",
    status: :open,
    revision: 1,
    stats: %{},
    timeline: []
  ]

  @type status :: :open | :sent_back | :accepted | :closed

  @typedoc "Where it comes from: the repository in the VM (its git folder), its worktree, its branch."
  @type source :: %{folder: String.t(), top: String.t(), branch: String.t()}

  @typedoc "How and where it was accepted, and what undoing it needs."
  @type accepted :: %{
          how: :changes | :commits,
          worktree: Path.t() | nil,
          branch: String.t(),
          undo: map() | nil,
          at: DateTime.t()
        }

  @type event :: %{at: DateTime.t(), kind: atom(), text: String.t()}

  @type t :: %__MODULE__{
          id: pos_integer(),
          title: String.t(),
          body: String.t(),
          agent: String.t() | nil,
          thread: String.t() | nil,
          thread_id: String.t() | nil,
          project: String.t(),
          repo: Path.t(),
          onto: String.t(),
          source: source(),
          head: String.t(),
          opened_at: DateTime.t(),
          updated_at: DateTime.t() | nil,
          accepted: accepted() | nil,
          base_commit: String.t() | nil,
          status: status(),
          revision: pos_integer(),
          stats: map(),
          timeline: [event()]
        }

  @type facts :: %{
          tip: String.t(),
          merge_base: String.t(),
          commits: [map()],
          files: [map()],
          added: non_neg_integer(),
          removed: non_neg_integer(),
          behind: non_neg_integer(),
          conflicts: [String.t()],
          hints: [String.t()]
        }

  @type refusal ::
          :not_a_repository
          | :not_in_a_project
          | :in_the_mirror
          | {:not_a_target, String.t(), [String.t()]}
          | :onto_itself
          | {:catch_up, String.t(), [String.t()]}
          | :detached
          | {:uncommitted, String.t()}
          | :bad_branch
          | :unrelated
          | :too_large
          | :no_title

  @title_limit 200
  @body_limit 16 * 1024
  @size_limit_mib 1024
  @diff_shown 2 * 1024 * 1024
  @diff_lines 6_000
  @commits_shown 250

  # Read in the VM, in the folder the agent ran `mdt handoff` in: the worktree's
  # top, the repository's git folder, its branch, its remotes, and what
  # isn't committed.
  @look """
  cd "$1" 2>/dev/null || exit 3
  top=$(git rev-parse --show-toplevel 2>/dev/null) || exit 3
  common=$(cd "$(git rev-parse --git-common-dir)" && pwd -P)
  branch=$(git symbolic-ref --quiet --short HEAD || true)
  printf '%s\\n%s\\n%s\\n' "$(cd "$top" && pwd -P)" "$common" "$branch"
  git config --get-regexp '^remote\\..*\\.url$' | head -20
  echo --
  git status --porcelain | head -20
  """

  # Files that run on your machine when you build, commit or open the
  # project. A hint, not a review.
  @runs [
    {~r{(^|/)(mix\.exs|Makefile|GNUmakefile|makefile|justfile|Justfile|Rakefile|package\.json|build\.gradle(\.kts)?|build\.rs|Cargo\.toml|setup\.py|pyproject\.toml|CMakeLists\.txt)$},
     "which runs when you build"},
    {~r{(^|/)(\.envrc|\.tool-versions|mise\.toml|\.mise\.toml)$},
     "which your shell and tools read"},
    {~r{^(\.husky|\.githooks)/|(^|/)\.pre-commit-config\.yaml$}, "which runs when you commit"},
    {~r{^(\.vscode|\.zed|\.idea)/}, "which your editor reads"},
    {~r{^\.github/workflows/|(^|/)\.gitlab-ci\.yml$}, "which runs in CI"}
  ]

  @doc "The most new data one handoff may bring, in MiB."
  def size_limit_mib, do: @size_limit_mib

  @doc """
  Reads the repository the agent is in, in the VM: where it is, its
  branch and remotes. Refuses a folder in no repository, a detached HEAD,
  and anything not committed.
  """
  @spec look(Guest.t(), String.t() | nil) ::
          {:ok, %{source: source(), remotes: [String.t()]}} | {:error, refusal()}
  def look(guest, cwd) do
    with {:ok, output} <- guest.exec.(["sh", "-c", @look, "mdt-handoff", text(cwd)]),
         [top, folder, branch | rest] when top != "" and folder != "" <-
           String.split(output, "\n"),
         {remotes, ["--" | dirty]} <- Enum.split_while(rest, &(&1 != "--")) do
      dirty = dirty |> Enum.join("\n") |> String.trim_trailing()

      cond do
        branch == "" ->
          {:error, :detached}

        dirty != "" ->
          {:error, {:uncommitted, dirty}}

        not ref?(branch) ->
          {:error, :bad_branch}

        true ->
          {:ok,
           %{
             source: %{folder: folder, top: top, branch: branch},
             remotes:
               for(
                 line <- remotes,
                 [_key, url] <- [String.split(line, " ", parts: 2)],
                 do: String.trim(url)
               )
           }}
      end
    else
      _ -> {:error, :not_a_repository}
    end
  end

  # The branch's name comes from the VM and goes into refs and commands.
  defp ref?(branch) do
    branch =~ ~r"\A[A-Za-z0-9][A-Za-z0-9._/-]{0,199}\z" and
      not String.contains?(branch, ["..", "//", "@{"]) and
      not String.ends_with?(branch, ["/", ".", ".lock"])
  end

  @doc "The agent's words, cleaned for showing: title, body, agent, thread and thread id."
  @spec words(map()) :: map()
  def words(ask) do
    line = fn key, limit ->
      case ask |> Map.get(key) |> shown() |> String.trim() |> String.slice(0, limit) do
        "" -> nil
        text -> text
      end
    end

    %{
      title: line.(:title, @title_limit) || "",
      body: ask |> Map.get(:body) |> shown() |> String.slice(0, @body_limit),
      agent: line.(:agent, 60),
      thread: line.(:thread, 200),
      thread_id: line.(:thread_id, 100)
    }
  end

  @doc """
  What MDT works out about a handoff against your repository as it is now:
  the commits it brings, the files it changes, how far the target branch
  has moved since, and whether the two merge.

  Once accepted, its commits and files are read from the commit it was
  built on (`base_commit`), since the target branch may hold them by then.
  """
  @spec facts(Path.t(), t()) :: {:ok, facts()} | {:error, String.t()}
  def facts(store, %__MODULE__{repo: repo, onto: onto, head: head} = handoff) do
    with tip when is_binary(tip) <-
           HostGit.line(repo, ["rev-parse", "--verify", "--quiet", "refs/heads/#{onto}^{commit}"]) ||
             {:error, "Your branch #{onto} is gone."} do
      HandoffStore.view(store, fn env ->
        merge_base =
          if handoff.status == :accepted and is_binary(handoff.base_commit),
            do: handoff.base_commit,
            else: line(store, ["merge-base", head, tip], env)

        with merge_base when is_binary(merge_base) <-
               merge_base || {:error, "It shares no history with #{onto} any more."} do
          files = numstat(store, merge_base, head, env)

          {:ok,
           %{
             tip: tip,
             merge_base: merge_base,
             commits: commits(store, merge_base, head, env),
             files: Enum.map(files, &%{&1 | path: Shown.text(&1.path)}),
             added: files |> Enum.map(&(&1.added || 0)) |> Enum.sum(),
             removed: files |> Enum.map(&(&1.removed || 0)) |> Enum.sum(),
             behind: number(store, ["rev-list", "--count", "#{head}..#{tip}"], env),
             conflicts: store |> conflicts(tip, head, env) |> Enum.map(&Shown.text/1),
             hints: hints(files)
           }}
        end
      end)
    end
  end

  @doc "The size of a handoff, kept on its record for the list."
  @spec stats(facts()) :: map()
  def stats(facts) do
    %{
      commits: length(facts.commits),
      files: length(facts.files),
      added: facts.added,
      removed: facts.removed,
      conflicts: length(facts.conflicts)
    }
  end

  defp numstat(store, from, to, env) do
    case HostGit.run(store, ["diff", "--numstat", "--no-renames", "-z", from, to], env: env) do
      {:ok, output} ->
        for entry <- String.split(output, <<0>>, trim: true),
            [added, removed, path] <- [String.split(entry, "\t", parts: 3)] do
          %{path: path, added: count(added), removed: count(removed)}
        end

      {:error, _} ->
        []
    end
  end

  defp commits(store, tip, head, env) do
    format = "--format=%H%x1f%an%x1f%aI%x1f%s%x1e"

    case HostGit.run(
           store,
           ["log", format, "--max-count=#{@commits_shown}", "#{tip}..#{head}"],
           env: env
         ) do
      {:ok, output} ->
        for record <- String.split(output, "\x1e", trim: true),
            [sha, author, at, subject] <- [record |> String.trim() |> String.split("\x1f")] do
          %{
            sha: sha,
            author: Shown.text(author),
            at: datetime(at),
            subject: Shown.text(subject)
          }
        end

      {:error, _} ->
        []
    end
  end

  defp datetime(text) do
    case DateTime.from_iso8601(text) do
      {:ok, at, _offset} -> at
      _ -> nil
    end
  end

  @doc """
  The files that hold conflicts when `theirs` is merged into `ours`: empty
  when it merges cleanly. Run with a `HandoffStore.view/2` environment.
  """
  @spec conflicts(Path.t(), String.t(), String.t(), list()) :: [String.t()]
  def conflicts(repo, ours, theirs, env) do
    case merge_tree(repo, ours, theirs, env) do
      {:ok, _tree, conflicts} -> conflicts
      {:error, _} -> []
    end
  end

  @doc """
  The merge of `theirs` into `ours`, computed without touching any working
  tree: the tree it makes, and the files in it that hold conflict markers.
  """
  @spec merge_tree(Path.t(), String.t(), String.t(), list()) ::
          {:ok, String.t(), [String.t()]} | {:error, String.t()}
  def merge_tree(repo, ours, theirs, env \\ []) do
    case HostGit.run(repo, ["merge-tree", "--write-tree", "--name-only", "-z", ours, theirs],
           ok: [0, 1],
           env: env
         ) do
      {:ok, output} ->
        case String.split(output, <<0>>) do
          [tree | rest] when byte_size(tree) >= 40 ->
            {:ok, tree, rest |> Enum.take_while(&(&1 != "")) |> Enum.uniq()}

          _ ->
            {:error, "git could not merge it: " <> Shown.text(String.slice(output, 0, 300))}
        end

      {:error, message} ->
        {:error, message}
    end
  end

  defp hints(files) do
    for %{path: path} <- files,
        {pattern, why} <- @runs,
        path =~ pattern,
        uniq: true,
        do: "It changes #{Shown.text(path)}, #{why}."
  end

  @doc """
  The change, file by file, against the commit it was built on: each a
  `MDTClient.Git.FileDiff` (side `:commit`). At most the first 2 MiB and
  #{@diff_lines} lines are read; `cut?` says there was more.
  """
  @spec diff(Path.t(), t(), String.t()) ::
          {:ok, %{files: [FileDiff.t()], cut?: boolean()}} | {:error, String.t()}
  def diff(store, %__MODULE__{head: head}, merge_base) do
    HandoffStore.view(store, fn env ->
      args = ["-c", "core.quotePath=false", "diff", "--no-color", "--no-ext-diff"]

      case HostGit.run(store, args ++ ["--find-renames", merge_base, head],
             env: env,
             max: @diff_shown,
             cut: true
           ) do
        {:ok, output} -> {:ok, %{files: files(output), cut?: false}}
        {:cut, output} -> {:ok, %{files: files(output), cut?: true}}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  # A unified diff of many files, split at each file's header and read by
  # the Git tool's own reader.
  defp files(output) do
    output
    |> Shown.text()
    |> String.split(~r/^(?=diff --git )/m, trim: true)
    |> Enum.filter(&String.starts_with?(&1, "diff --git "))
    |> Enum.map_reduce(@diff_lines, fn chunk, budget ->
      diff = Files.parse_diff(chunk, path(chunk), :commit, max(budget, 1))
      used = diff.hunks |> Enum.map(&length(&1.lines)) |> Enum.sum()
      {%{diff | truncated?: diff.truncated? or budget <= 0}, budget - used}
    end)
    |> elem(0)
  end

  defp path(chunk) do
    lines = String.split(chunk, "\n", parts: 12)

    Enum.find_value(lines, fn
      "+++ b/" <> path -> path
      "rename to " <> path -> path
      _ -> nil
    end) ||
      Enum.find_value(lines, fn
        "--- a/" <> path -> path
        _ -> nil
      end) ||
      case Regex.run(~r{^diff --git a/(.*) b/}, hd(lines)) do
        [_, path] -> path
        _ -> hd(lines)
      end
  end

  @doc "Why a handoff was not taken, in words for the agent."
  @spec explain(refusal() | String.t()) :: String.t()
  def explain(:no_title), do: "Give it a title: mdt handoff --title \"what this is\""

  def explain(:not_a_repository),
    do: "This folder isn't in a git repository. Run mdt handoff in your worktree."

  def explain(:not_in_a_project),
    do:
      "This repository isn't a project MDT mirrors, so there is nothing to hand off to. Work in a worktree of a project under /work: mdt project says which."

  def explain(:in_the_mirror),
    do:
      "This is the project's mirror, the user's branch as they committed it: view only. Work in a worktree of your own (mdt worktree new TASK) and hand off from there."

  def explain({:not_a_target, onto, targets}),
    do:
      "#{onto} isn't a target branch of this project. Its target branches: #{Enum.join(targets, ", ")}. Ask the user which one when you aren't sure."

  def explain(:onto_itself),
    do: "This worktree is on the target branch itself. Work on a branch of your own."

  def explain({:catch_up, onto, files}),
    do:
      "This doesn't merge with the user's #{onto} as it is now, in: #{Enum.join(files, ", ")}. Catch up first: git merge host/#{onto}, resolve, commit, then mdt handoff again."

  def explain(:detached), do: "This worktree is on no branch. Hand off a branch."

  def explain({:uncommitted, files}),
    do: "Commit or discard these first; a handoff is what you committed:\n" <> files

  def explain(:bad_branch),
    do: "MDT can't take a branch with that name. Use letters, digits, dots, dashes and slashes."

  def explain(:unrelated),
    do:
      "This branch shares no history with the user's branch, so there is nothing to compare it to."

  def explain(:too_large),
    do:
      "This brings more than #{div(@size_limit_mib, 1024)} GiB of new data, which is more than MDT takes. Leave large generated files out of the commits."

  def explain(text) when is_binary(text), do: text

  defp line(repo, args, env) do
    case HostGit.run(repo, args, env: env) do
      {:ok, output} -> output |> String.trim() |> then(&if(&1 == "", do: nil, else: &1))
      {:error, _} -> nil
    end
  end

  defp number(repo, args, env) do
    case line(repo, args, env) do
      nil -> 0
      text -> String.to_integer(text)
    end
  end

  defp count("-"), do: nil
  defp count(text), do: String.to_integer(text)

  defp text(value) when is_binary(value), do: value
  defp text(_other), do: ""

  # The agent's words, for you to read.
  defp shown(value), do: value |> text() |> Shown.text()
end
