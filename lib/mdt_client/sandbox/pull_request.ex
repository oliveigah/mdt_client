defmodule MDTClient.Sandbox.PullRequest do
  @moduledoc """
  The VM's work back to you, the way an agent would open a pull request:
  one branch of a git repository in the VM, offered to a branch of one of
  your repositories, with a title and a description.

  There is no project to set up. The repository is the project: the agent
  runs `mdt pr` in any git repository in the VM, and MDT works out which
  repository of yours it is for (`MDTClient.Sandbox.PullTarget`). Its
  commits wait in MDT's own store (`MDTClient.Sandbox.PullStore`), so
  nothing is written into your repository until you bring it in
  (`MDTClient.Sandbox.Landing`), where and how you choose.

  Running `mdt pr` again on the same branch updates the pull request while
  it is open, as pushing to a pull request's branch does.

  `title`, `body`, `agent` and the commit messages are the agent's words:
  claims. What MDT works out itself is in `facts/2`.
  """

  alias MDTClient.Git.{FileDiff, Files}
  alias MDTClient.Sandbox.{Guest, HostGit, PullStore, Shown}

  @enforce_keys [:id, :title, :repo, :base, :source, :head, :opened_at]
  defstruct [
    :id,
    :title,
    :agent,
    :repo,
    :base,
    :source,
    :head,
    :opened_at,
    :updated_at,
    :landed,
    :base_commit,
    body: "",
    status: :open,
    revision: 1,
    stats: %{},
    timeline: []
  ]

  @type status :: :open | :changes_requested | :merged | :closed

  @typedoc "Where it comes from: the repository in the VM (its git folder), its worktree, its branch."
  @type source :: %{folder: String.t(), top: String.t(), branch: String.t()}

  @typedoc "Where and how it was brought in, and what undoing it needs."
  @type landed :: %{
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
          repo: Path.t(),
          base: String.t(),
          source: source(),
          head: String.t(),
          opened_at: DateTime.t(),
          updated_at: DateTime.t() | nil,
          landed: landed() | nil,
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
          | :detached
          | {:uncommitted, String.t()}
          | :bad_branch
          | :unrelated
          | :too_large
          | :no_title
          | {:no_base, String.t()}

  @title_limit 200
  @body_limit 16 * 1024
  @size_limit_mib 1024
  @diff_shown 2 * 1024 * 1024
  @diff_lines 6_000
  @commits_shown 250

  # Read in the VM, in the folder the agent ran `mdt pr` in: the worktree's
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

  @doc "The most new data one pull request may bring, in MiB."
  def size_limit_mib, do: @size_limit_mib

  @doc """
  Reads the repository the agent is in, in the VM: where it is, its
  branch and remotes. Refuses a folder in no repository, a detached HEAD,
  and anything not committed.
  """
  @spec look(Guest.t(), String.t() | nil) ::
          {:ok, %{source: source(), remotes: [String.t()]}} | {:error, refusal()}
  def look(guest, cwd) do
    with {:ok, output} <- guest.exec.(["sh", "-c", @look, "mdt-pr", text(cwd)]),
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

  @doc "The base branch: the one the agent named, else the one checked out in your repository."
  @spec base(Path.t(), String.t() | nil) :: {:ok, String.t()} | {:error, refusal()}
  def base(repo, claim) do
    name = if claim in [nil, ""], do: HostGit.branch(repo), else: String.trim(claim)
    name = name && String.replace_prefix(name, "refs/heads/", "")

    cond do
      is_binary(name) and ref?(name) and
          HostGit.line(repo, ["rev-parse", "--verify", "--quiet", "refs/heads/#{name}"]) != nil ->
        {:ok, name}

      true ->
        # Your branches' names aren't the VM's to read: it is told to ask.
        {:error, {:no_base, Shown.text(name || "")}}
    end
  end

  @doc "Your repository's local branches, by name."
  @spec branches(Path.t()) :: [String.t()]
  def branches(repo) do
    case HostGit.run(repo, ["for-each-ref", "--format=%(refname:short)", "refs/heads"]) do
      {:ok, output} -> String.split(output, "\n", trim: true)
      {:error, _} -> []
    end
  end

  @doc "The agent's words, cleaned for showing: `{title, body, agent}`."
  @spec words(map()) :: {String.t(), String.t(), String.t() | nil}
  def words(ask) do
    title = ask |> Map.get(:title) |> shown() |> String.trim() |> String.slice(0, @title_limit)
    body = ask |> Map.get(:body) |> shown() |> String.slice(0, @body_limit)
    agent = ask |> Map.get(:agent) |> shown() |> String.trim() |> String.slice(0, 60)
    {title, body, if(agent == "", do: nil, else: agent)}
  end

  @doc """
  What MDT works out about a pull request against your repository as it is
  now: the commits it brings, the files it changes, how far your base
  branch has moved since, and whether the two merge.

  Once brought in, its commits and files are read from the commit it was
  built on (`base_commit`), since your base may hold them by then.
  """
  @spec facts(Path.t(), t()) :: {:ok, facts()} | {:error, String.t()}
  def facts(store, %__MODULE__{repo: repo, base: base, head: head} = pull) do
    with tip when is_binary(tip) <-
           HostGit.line(repo, ["rev-parse", "--verify", "--quiet", "refs/heads/#{base}^{commit}"]) ||
             {:error, "Your branch #{base} is gone."} do
      PullStore.view(store, fn env ->
        merge_base =
          if pull.status == :merged and is_binary(pull.base_commit),
            do: pull.base_commit,
            else: line(store, ["merge-base", head, tip], env)

        with merge_base when is_binary(merge_base) <-
               merge_base || {:error, "It shares no history with #{base} any more."} do
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

  @doc "The size of a pull request, kept on its record for the list."
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
  when it merges cleanly. Run with a `PullStore.view/2` environment.
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
    PullStore.view(store, fn env ->
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

  @doc "Why a pull request was not taken, in words for the agent."
  @spec explain(refusal() | String.t()) :: String.t()
  def explain(:no_title), do: "Give it a title: mdt pr --title \"what this is\""

  def explain(:not_a_repository),
    do: "This folder isn't in a git repository. Run mdt pr in the repository you worked in."

  def explain(:detached), do: "This worktree is on no branch. Open a pull request from a branch."

  def explain({:uncommitted, files}),
    do: "Commit or discard these first; a pull request is what you committed:\n" <> files

  def explain(:bad_branch),
    do: "MDT can't take a branch with that name. Use letters, digits, dots, dashes and slashes."

  def explain(:unrelated),
    do:
      "This branch shares no history with the user's branch, so there is nothing to compare it to."

  def explain(:too_large),
    do:
      "This brings more than #{div(@size_limit_mib, 1024)} GiB of new data, which is more than MDT takes. Leave large generated files out of the commits."

  def explain({:no_base, ""}),
    do:
      "The user is on no branch there. Name their branch this is for with mdt pr --base BRANCH, and ask them which when you don't know."

  def explain({:no_base, name}),
    do:
      "The user's repository has no branch #{name}. Name their branch with mdt pr --base BRANCH, and ask them which when you don't know."

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
