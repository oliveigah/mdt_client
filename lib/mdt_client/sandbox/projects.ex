defmodule MDTClient.Sandbox.Projects do
  @moduledoc """
  The projects of one identity, as the pages and the agent channel use
  them: opening a repository in the VM, its settings, its mirror and its
  agent worktrees.

  The sandbox (`MDTClient.Sandbox.Server`) keeps the records; the git work
  runs here, in the caller's process, or in the server's mirror task
  (`follow/5`), so the server never waits on it.

  Everything that reaches into the VM needs it running. Tests set
  `config :mdt_client, MDTClient.Sandbox.Projects, guest: guest` to put a
  folder of this machine in its place.
  """

  alias MDTClient.Sandbox.{Guest, Handoffs, HostGit, Mirror, Project, Server, Shown, Zed}

  @type error ::
          :vm_not_running
          | :not_found
          | :not_in_a_project
          | {:bad_task, String.t()}
          | {:task_taken, String.t()}
          | Project.error()
          | Zed.error()
          | String.t()

  @doc "Every project, in the order they were added."
  @spec list(String.t()) :: [Project.t()]
  def list(username), do: Server.call(username, :projects).projects

  @doc """
  Makes the repository `path` is in a project, and mirrors it into the VM
  when the VM runs. A repository that is a project already is that project.
  """
  @spec add(String.t(), String.t()) :: {:ok, Project.t()} | {:error, error()}
  def add(username, path) do
    %{projects: projects, shares: shares} = Server.call(username, :projects)

    with {:ok, top} <- Project.check(path, shares: shares) do
      case Enum.find(projects, &(&1.path == top)) do
        %Project{} = project ->
          {:ok, project}

        nil ->
          with {:ok, project} <- Project.new(top, projects, shares: shares),
               {:ok, project} <- Server.call(username, {:add_project, project}) do
            mirror(username, project.name)
            {:ok, project}
          end
      end
    end
  end

  @doc """
  Opens a project in Zed: its mirror, or `folder`, a folder of the VM (an
  agent worktree). The mirror is brought up to date first.
  """
  @spec open(String.t(), String.t(), String.t() | nil) :: :ok | {:error, error()}
  def open(username, name, folder \\ nil) do
    with {:ok, project, %{vm: vm}} <- find(username, name),
         {:ok, guest} <- guest(username, vm),
         {:ok, _} <- mirror(username, name) do
      Zed.open(username, folder || Project.mirror_path(project, guest))
    end
  end

  @doc "Saves a project's settings (`MDTClient.Sandbox.Project.update/2`), and mirrors what they changed."
  @spec update(String.t(), String.t(), map()) :: {:ok, Project.t()} | {:error, error()}
  def update(username, name, attrs) do
    with {:ok, project, _} <- find(username, name),
         {:ok, updated} <- Project.update(project, attrs),
         {:ok, updated} <-
           Server.call(username, {:put_project, updated, "Settings of #{name} saved"}) do
      mirror(username, name)
      {:ok, updated}
    end
  end

  @doc "Stops a repository being a project. Its mirror and worktrees in the VM stay, for the VM to delete."
  @spec remove(String.t(), String.t()) :: :ok | {:error, error()}
  def remove(username, name) do
    with {:ok, _project} <- Server.call(username, {:remove_project, name}), do: :ok
  end

  @doc """
  Updates a project's mirror now, and keeps the handoffs' sizes and
  conflicts current with your branches. Without a running VM there is
  nothing to update: `{:error, :vm_not_running}`, and the server mirrors
  it once the VM runs.
  """
  @spec mirror(String.t(), String.t()) :: {:ok, Mirror.result()} | {:error, error()}
  def mirror(username, name) do
    with {:ok, project, %{vm: vm}} <- find(username, name),
         {:ok, guest} <- guest(username, vm) do
      update_mirror(username, project, guest, vm)
    end
  end

  defp update_mirror(username, project, guest, vm) do
    result = Mirror.run(project, guest)

    entry =
      case result do
        {:ok, done} ->
          Map.merge(done, %{targets: project.targets, error: nil})

        {:error, text} ->
          %{tips: Mirror.tips(project), default: project.default_target, rescued: nil}
          |> Map.merge(%{targets: project.targets, error: text})
      end
      |> Map.merge(%{at: now(), vm_started_at: vm[:started_at]})

    Server.call(username, {:mirrored, project.name, entry})
    if match?({:ok, _}, result), do: Handoffs.refresh(username, project.name)
    result
  end

  @doc """
  One look at every mirror, for the server's task: each whose branches
  moved, whose settings changed, or that the VM hasn't had since it
  started, is updated. A failed one is tried again after `retry` seconds.
  """
  @spec follow(String.t(), [Project.t()], map(), map(), pos_integer()) :: :ok
  def follow(username, projects, mirror, vm, retry) do
    with {:ok, guest} <- guest(username, vm) do
      for project <- projects do
        last = Map.get(mirror, project.name)
        tips = Mirror.tips(project)

        current? =
          last != nil and last.tips == tips and last.default == project.default_target and
            last.targets == project.targets and last.vm_started_at == vm[:started_at]

        waiting? =
          last != nil and last.error != nil and
            DateTime.diff(now(), last.at) < retry

        unless current? and (last.error == nil or waiting?),
          do: update_mirror(username, project, guest, vm)
      end
    end

    :ok
  end

  @doc """
  The project's agent worktrees in the VM: each one's folder and branch,
  the mirror left out.
  """
  @spec worktrees(String.t(), String.t()) :: {:ok, [map()]} | {:error, error()}
  def worktrees(username, name) do
    with {:ok, project, %{vm: vm}} <- find(username, name),
         {:ok, guest} <- guest(username, vm) do
      mirror = Project.mirror_path(project, guest)

      case guest.exec.(["git", "-C", mirror, "worktree", "list", "--porcelain"]) do
        {:ok, output} ->
          {:ok,
           output
           |> String.split("\n\n", trim: true)
           |> Enum.map(&String.split(&1, "\n", trim: true))
           |> Enum.flat_map(fn
             ["worktree " <> path | fields] when path != mirror ->
               branch =
                 Enum.find_value(fields, fn
                   "branch refs/heads/" <> branch -> branch
                   _ -> nil
                 end)

               [%{path: Shown.text(path), branch: branch && Shown.text(branch)}]

             _ ->
               []
           end)}

        {:error, _} ->
          {:ok, []}
      end
    end
  end

  ## What agents ask through the channel

  @doc "The project the folder `cwd` of the VM is in, and where in it: `:mirror` or the worktree's top."
  @spec locate(String.t(), String.t() | nil) ::
          {:ok, Project.t(), :mirror | {:worktree, String.t()}, Guest.t()} | {:error, error()}
  def locate(username, cwd) do
    %{projects: projects, vm: vm} = Server.call(username, :projects)

    script =
      ~s|cd "$1" 2>/dev/null && git rev-parse --show-toplevel && cd "$(git rev-parse --git-common-dir)" && pwd -P|

    with {:ok, guest} <- guest(username, vm),
         {:ok, output} <-
           guest.exec.(["sh", "-c", script, "mdt-project", if(is_binary(cwd), do: cwd, else: "")]),
         [top, folder] <- String.split(String.trim(output), "\n"),
         %Project{} = project <- Project.of_folder(projects, guest, folder) do
      where = if top == Project.mirror_path(project, guest), do: :mirror, else: {:worktree, top}
      {:ok, project, where, guest}
    else
      {:error, :vm_not_running} -> {:error, :vm_not_running}
      _ -> {:error, :not_in_a_project}
    end
  end

  @doc """
  Makes an agent worktree, `/work/<name>.wt/<task>`, on a new branch
  `task` started from your target branch `onto` (the default unless
  named), as it is in the mirror.
  """
  @spec new_worktree(String.t(), String.t() | nil, String.t(), String.t() | nil) ::
          {:ok, Project.t(), Path.t(), String.t()}
          | {:error, error() | MDTClient.Sandbox.Handoff.refusal()}
  def new_worktree(username, cwd, task, onto) do
    task = task |> to_string() |> String.trim()

    with {:ok, project, _where, guest} <- locate(username, cwd),
         onto = if(onto in [nil, ""], do: project.default_target, else: onto),
         true <-
           onto in project.targets or {:error, {:not_a_target, onto, project.targets}},
         true <- task?(task) or {:error, {:bad_task, Shown.text(task)}},
         path = Path.join(Project.worktrees_path(project, guest), String.replace(task, "/", "-")),
         {:ok, _} <-
           guest.exec.([
             "git",
             "-C",
             Project.mirror_path(project, guest),
             "worktree",
             "add",
             "--quiet",
             "--no-track",
             "-b",
             task,
             path,
             "refs/remotes/host/#{onto}"
           ]) do
      {:ok, project, path, onto}
    else
      {:error, text} when is_binary(text) -> {:error, {:task_taken, task}}
      {:error, reason} -> {:error, reason}
    end
  end

  # A branch name, and a folder name once its slashes are dashes.
  defp task?(task) do
    task =~ ~r"\A[A-Za-z0-9][A-Za-z0-9._/-]{0,99}\z" and
      not String.contains?(task, ["..", "//", "@{"]) and
      not String.ends_with?(task, ["/", ".", ".lock"])
  end

  ## Shared

  defp find(username, name) do
    %{projects: projects} = context = Server.call(username, :projects)

    case Enum.find(projects, &(&1.name == name)) do
      nil -> {:error, :not_found}
      project -> {:ok, project, context}
    end
  end

  @doc "The VM to reach into, or `{:error, :vm_not_running}`."
  @spec guest(String.t(), map()) :: {:ok, Guest.t()} | {:error, :vm_not_running}
  def guest(username, vm) do
    case Application.get_env(:mdt_client, __MODULE__, [])[:guest] do
      nil when vm.status == :running -> {:ok, Guest.vm(username, vm.name)}
      nil -> {:error, :vm_not_running}
      guest -> {:ok, guest}
    end
  end

  @doc "The branch your repository has checked out, or nil."
  @spec checked_out(Project.t()) :: String.t() | nil
  def checked_out(%Project{path: path}), do: HostGit.branch(path)

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  @doc "Why something here didn't happen, in words."
  @spec explain(error()) :: String.t()
  def explain(:vm_not_running), do: "The VM isn't running."
  def explain(:not_found), do: "That project is gone."

  def explain(:not_in_a_project),
    do:
      "This folder isn't in a project MDT mirrors. The user opens a repository from MDT's Projects page; it appears at /work/NAME."

  def explain({:bad_task, task}),
    do: "\"#{task}\" can't be a branch name. Use letters, digits, dots, dashes and slashes."

  def explain({:task_taken, task}),
    do: "There is a branch or worktree called #{task} already. Choose another name."

  def explain(reason)
      when reason in [:no_zed, :no_ssh_entry] or
             (is_tuple(reason) and elem(reason, 0) == :other_ssh_entry),
      do: Zed.explain(reason)

  def explain({:not_a_target, _onto, _targets} = reason),
    do: MDTClient.Sandbox.Handoff.explain(reason)

  def explain(reason) when is_binary(reason), do: reason
  def explain(reason), do: Project.explain(reason)
end
