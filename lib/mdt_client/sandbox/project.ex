defmodule MDTClient.Sandbox.Project do
  @moduledoc """
  A git repository of yours that MDT mirrors into the VM, and the rules
  agents follow in it.

  In the VM a project is one git repository on the Work disk:

    * **the mirror**, its main worktree at `/work/<name>`: your target
      branch as committed, kept current by MDT (`MDTClient.Sandbox.Mirror`)
      and view only;
    * **worktree slots** beside it, `/work/<name>.wt/slot-1` to
      `slot-<slots>`: fixed folders agents take one task at a time, each
      task on a branch of its own (`MDTClient.Sandbox.Slots`). Older
      projects may have per-task worktrees there too, which keep working.
      They all share the mirror's refs, so `host/<branch>` is your branch
      as it is now in every one of them, and an agent catches up with
      `git merge host`.

  Work comes back as handoffs (`MDTClient.Sandbox.Handoff`) to one of the
  project's `targets`, `default_target` unless the agent names another.
  `accept` is how a handoff is accepted unless you choose otherwise.

  A project is made the first time you open a repository in the VM, and
  only for a repository the VM can't write (`check/2`).
  """

  alias MDTClient.Sandbox.{HostGit, Share, Shares}

  @enforce_keys [:name, :path, :default_target]
  defstruct [:name, :path, :default_target, :added_at, targets: [], accept: :commits, slots: 3]

  @max_slots 9

  @type accept :: :commits | :changes

  @type t :: %__MODULE__{
          name: String.t(),
          path: Path.t(),
          default_target: String.t(),
          targets: [String.t()],
          accept: accept(),
          slots: pos_integer(),
          added_at: DateTime.t() | nil
        }

  @type error ::
          {:not_a_repository, String.t()}
          | {:no_commit, String.t()}
          | {:writable, String.t()}
          | {:refused, String.t(), String.t()}
          | :detached
          | :already_added
          | :no_targets
          | {:not_a_branch, String.t()}
          | :default_not_a_target
          | :bad_slots

  @doc """
  The project for the repository `path` is in, not one of `existing`. Its
  target branch is the branch checked out there. Options: `:shares`,
  `:home`, `:data_dir` (`check/2`).
  """
  @spec new(String.t(), [t()], keyword()) :: {:ok, t()} | {:error, error()}
  def new(path, existing, opts \\ []) do
    with {:ok, top} <- check(path, opts),
         false <- Enum.any?(existing, &(&1.path == top)) && {:error, :already_added},
         branch when is_binary(branch) <- HostGit.branch(top) || {:error, :detached} do
      {:ok,
       %__MODULE__{
         name: name(Path.basename(top), existing),
         path: top,
         default_target: branch,
         targets: [branch],
         added_at: DateTime.utc_now() |> DateTime.truncate(:second)
       }}
    end
  end

  # Letters, digits, dot, dash and underscore: a folder name that needs no
  # quoting anywhere. Two repositories with one name get a number.
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

  @doc """
  Checks the folder `path` on your machine: the top folder of its
  repository, when that is one MDT may mirror and run git in.

  The repository, its git folder and the folder its worktrees share must
  not be in or hold a read-write share (a `.git` the VM can write could hold
  a hook or a `core.fsmonitor` line that runs here), MDT's data folder, or a
  folder shares refuse (`MDTClient.Sandbox.Shares.refused/2`).

  Options: `:shares`, `:home`, `:data_dir`.
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

  @doc """
  The project with the settings a form sent: `targets` (branch names),
  `default_target`, `accept` (`"commits"` or `"changes"`) and `slots`
  (how many worktree slots, 1 to 9), checked against the repository's
  branches. A field not sent stays as it is.
  """
  @spec update(t(), map()) :: {:ok, t()} | {:error, error()}
  def update(%__MODULE__{} = project, attrs) do
    branches = branches(project)
    targets = attrs |> Map.get("targets", project.targets) |> List.wrap() |> Enum.uniq()
    default = Map.get(attrs, "default_target", project.default_target)

    accept =
      case Map.get(attrs, "accept") do
        "changes" -> :changes
        "commits" -> :commits
        _ -> project.accept
      end

    slots =
      case Map.get(attrs, "slots", project.slots) do
        n when is_integer(n) -> n
        text when is_binary(text) -> parse_count(text)
        _ -> nil
      end

    cond do
      targets == [] ->
        {:error, :no_targets}

      missing = Enum.find(targets, &(&1 not in branches)) ->
        {:error, {:not_a_branch, missing}}

      default not in targets ->
        {:error, :default_not_a_target}

      slots not in 1..@max_slots//1 ->
        {:error, :bad_slots}

      true ->
        {:ok,
         %{project | targets: targets, default_target: default, accept: accept, slots: slots}}
    end
  end

  defp parse_count(text) do
    case Integer.parse(String.trim(text)) do
      {n, ""} -> n
      _ -> nil
    end
  end

  @doc "A project as saved by an older MDT, with the fields added since at their defaults."
  @spec upgrade(t() | map()) :: t()
  def upgrade(project), do: struct(__MODULE__, Map.drop(Map.from_struct(project), [:__struct__]))

  @doc "Your repository's local branches, by name."
  @spec branches(t() | Path.t()) :: [String.t()]
  def branches(%__MODULE__{path: path}), do: branches(path)

  def branches(path) when is_binary(path) do
    case HostGit.run(path, ["for-each-ref", "--format=%(refname:short)", "refs/heads"]) do
      {:ok, output} -> String.split(output, "\n", trim: true)
      {:error, _} -> []
    end
  end

  @doc "The mirror's folder in the VM: the project's main worktree."
  @spec mirror_path(t(), %{root: Path.t()}) :: Path.t()
  def mirror_path(%__MODULE__{name: name}, guest), do: Path.join(guest.root, name)

  @doc "Where worktree slots (and older per-task worktrees) go in the VM."
  @spec worktrees_path(t(), %{root: Path.t()}) :: Path.t()
  def worktrees_path(project, guest), do: mirror_path(project, guest) <> ".wt"

  @doc "The project whose repository in the VM has the git folder `folder`, or nil."
  @spec of_folder([t()], %{root: Path.t()}, String.t()) :: t() | nil
  def of_folder(projects, guest, folder),
    do: Enum.find(projects, &(Path.join(mirror_path(&1, guest), ".git") == folder))

  @doc "Why a folder can't be a project, or settings can't be saved, in words."
  @spec explain(error()) :: String.t()
  def explain({:not_a_repository, path}),
    do: "#{path} is not a folder in a git repository on your machine."

  def explain({:no_commit, path}), do: "The repository at #{path} has no commit yet."

  def explain({:writable, shared}),
    do:
      "That repository is in #{shared}, which the VM can write. MDT won't run git there: share it read-only, or move it."

  def explain({:refused, folder, what}),
    do: "That repository is in or holds #{folder}, which holds #{what}."

  def explain(:detached),
    do:
      "That repository is on no branch. Check out the branch agents hand their work to, then open it."

  def explain(:already_added), do: "That repository is a project already."
  def explain(:no_targets), do: "Choose at least one target branch."
  def explain({:not_a_branch, name}), do: "Your repository has no branch #{name}."
  def explain(:default_not_a_target), do: "The default must be one of the target branches."
  def explain(:bad_slots), do: "A project has 1 to #{@max_slots} worktree slots."
end
