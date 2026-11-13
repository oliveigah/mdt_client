defmodule MDTClient.Sandbox.Projects do
  @moduledoc """
  The projects and handoffs of one identity, as the pages and the agent
  channel use them.

  The sandbox (`MDTClient.Sandbox.Server`) keeps the records: which
  repositories are projects, and every handoff with where it stands. The
  work itself is git, on your repository and through the pipe into the VM
  (`MDTClient.Sandbox.Sync`, `MDTClient.Sandbox.Handoff`), and it runs here,
  in the caller's process, so the sandbox never waits on it.

  The VM must be running: a sync and a handoff both go into it. Tests set
  `config :mdt_client, MDTClient.Sandbox.Projects, guest: guest` to put a
  folder in its place.
  """

  alias MDTClient.Sandbox.{Guest, Handoff, Project, Server, Shown, Sync}

  @type error ::
          :vm_not_running
          | :not_found
          | :not_in_a_project
          | :not_waiting
          | :nothing_to_undo
          | Project.error()
          | Handoff.refusal()
          | {:conflicts | :in_the_way, [String.t()]}
          | String.t()

  ## Projects

  @doc "Makes the repository at `path` a project. The first sync copies it into the VM."
  @spec add(String.t(), String.t()) :: {:ok, Project.t()} | {:error, error()}
  def add(username, path) do
    %{projects: projects} = Server.call(username, :projects)

    with {:ok, project} <- Project.new(path, projects) do
      Server.call(username, {:add_project, project})
    end
  end

  @doc """
  Stops a repository being a project, and lets go of what its handoffs kept
  in it. The copy in the VM stays, for the VM to delete.
  """
  @spec remove(String.t(), String.t()) :: :ok | {:error, error()}
  def remove(username, name) do
    with {:ok, project, handoffs} <- Server.call(username, {:remove_project, name}) do
      Enum.each(handoffs, &let_go(project, &1))
      :ok
    end
  end

  @doc """
  Syncs a project into the VM: your branches as `host/…`, and with
  `uncommitted: true` your working tree as it is.
  """
  @spec sync(String.t(), String.t(), keyword()) :: {:ok, Sync.result()} | {:error, error()}
  def sync(username, name, opts \\ []) do
    %{projects: projects, vm: vm} = Server.call(username, :projects)

    with %Project{} = project <- Enum.find(projects, &(&1.name == name)) || {:error, :not_found},
         {:ok, guest} <- guest(username, vm),
         {:ok, result} <- Sync.run(project, guest, opts) do
      Server.call(username, {:project_synced, name, "#{name} synced into the VM"})
      {:ok, result}
    end
  end

  ## What agents ask through the channel

  @doc "The sync an agent asks for from `folder` in the VM: committed work only."
  @spec sync_from(String.t(), String.t()) ::
          {:ok, Project.t(), Sync.result()} | {:error, error()}
  def sync_from(username, folder) do
    with {:ok, project, guest, _handoffs} <- project_of(username, folder),
         {:ok, result} <- Sync.run(project, guest) do
      Server.call(
        username,
        {:project_synced, project.name, "#{project.name} synced into the VM, asked from there"}
      )

      {:ok, project, result}
    end
  end

  @doc "Takes the handoff an agent asks for; `ask` holds its words (`Handoff.receive/3`)."
  @spec hand_off(String.t(), map()) :: {:ok, Handoff.t()} | {:error, error()}
  def hand_off(username, ask) do
    with {:ok, project, guest, _handoffs} <- project_of(username, Map.get(ask, :cwd)),
         {:ok, handoff} <- Handoff.receive(project, guest, ask),
         {:ok, _replaced, dropped} <- Server.call(username, {:put_handoff, handoff}) do
      # The one it replaced gave its vm/<branch> to this one already.
      Enum.each(dropped, &Handoff.forget(project, &1))
      {:ok, handoff}
    end
  end

  @doc "The handoffs of the project `folder` in the VM belongs to, newest first."
  @spec handoffs_from(String.t(), String.t()) ::
          {:ok, Project.t(), [Handoff.t()]} | {:error, error()}
  def handoffs_from(username, folder) do
    with {:ok, project, _guest, handoffs} <- project_of(username, folder) do
      {:ok, project, Enum.filter(handoffs, &(&1.project == project.name))}
    end
  end

  ## What you do with a handoff

  @doc "What MDT works out about a handoff against your repository as it is now."
  @spec facts(String.t(), String.t()) :: {:ok, Handoff.facts()} | {:error, error()}
  def facts(username, id) do
    with {:ok, project, handoff} <- find(username, id), do: {:ok, Handoff.facts(project, handoff)}
  end

  @doc "A handoff's whole change, as a diff."
  @spec diff(String.t(), String.t()) :: {:ok, String.t()} | {:error, error()}
  def diff(username, id) do
    with {:ok, project, handoff} <- find(username, id), do: Handoff.diff(project, handoff)
  end

  @doc "Brings a waiting handoff into your working tree, whole and uncommitted."
  @spec bring(String.t(), String.t(), boolean()) :: {:ok, Handoff.t()} | {:error, error()}
  def bring(username, id, anyway? \\ false) do
    with {:ok, project, %Handoff{status: :waiting} = handoff} <- find(username, id),
         {:ok, undo} <- Handoff.bring(project, handoff, anyway?) do
      Handoff.hide(project, handoff)
      update(username, handoff, %{status: :brought, undo: undo}, "brought into your working tree")
    else
      {:ok, _project, _not_waiting} -> {:error, :not_waiting}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Undoes a bring: your working tree as it was, and the handoff waiting again."
  @spec undo(String.t(), String.t()) :: {:ok, Handoff.t()} | {:error, error()}
  def undo(username, id) do
    with {:ok, project, %Handoff{status: :brought, undo: %{} = undo} = handoff} <-
           find(username, id),
         :ok <- Handoff.undo(project, undo) do
      Handoff.show(project, handoff)

      update(
        username,
        handoff,
        %{status: :waiting, undo: nil, decided_at: nil},
        "taken back out of your working tree"
      )
    else
      {:ok, _project, _not_brought} -> {:error, :nothing_to_undo}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Sends a waiting handoff back with a note, which the agent reads with `mdt handoffs`."
  @spec send_back(String.t(), String.t(), String.t()) :: {:ok, Handoff.t()} | {:error, error()}
  def send_back(username, id, note),
    do: finish(username, id, :sent_back, String.trim(note), "sent back")

  @doc "Declines a waiting handoff."
  @spec decline(String.t(), String.t()) :: {:ok, Handoff.t()} | {:error, error()}
  def decline(username, id), do: finish(username, id, :declined, nil, "declined")

  defp finish(username, id, status, note, words) do
    case find(username, id) do
      {:ok, project, %Handoff{status: :waiting} = handoff} ->
        let_go(project, handoff)
        update(username, handoff, %{status: status, note: note}, words)

      {:ok, _project, _not_waiting} ->
        {:error, :not_waiting}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp update(username, handoff, changes, words) do
    changes = Map.put_new(changes, :decided_at, DateTime.utc_now() |> DateTime.truncate(:second))
    Server.call(username, {:update_handoff, handoff.id, changes, "\"#{handoff.title}\" #{words}"})
  end

  defp let_go(project, handoff) do
    Handoff.hide(project, handoff)
    Handoff.forget(project, handoff)
  end

  defp find(username, id) do
    %{projects: projects, handoffs: handoffs} = Server.call(username, :projects)

    with %Handoff{} = handoff <- Enum.find(handoffs, &(&1.id == id)) || {:error, :not_found},
         %Project{} = project <-
           Enum.find(projects, &(&1.name == handoff.project)) || {:error, :not_found} do
      {:ok, project, handoff}
    end
  end

  defp project_of(username, folder) do
    %{projects: projects, handoffs: handoffs, vm: vm} = Server.call(username, :projects)

    with {:ok, guest} <- guest(username, vm),
         %Project{} = project <-
           Project.of(projects, guest, if(is_binary(folder), do: folder, else: "")) ||
             {:error, :not_in_a_project} do
      {:ok, project, guest, handoffs}
    end
  end

  defp guest(username, vm) do
    case Application.get_env(:mdt_client, __MODULE__, [])[:guest] do
      nil when vm.status == :running -> {:ok, Guest.vm(username, vm.name)}
      nil -> {:error, :vm_not_running}
      guest -> {:ok, guest}
    end
  end

  @doc "Why something here didn't happen, in words."
  @spec explain(error()) :: String.t()
  def explain(:vm_not_running), do: "The VM isn't running."
  def explain(:not_found), do: "That is gone."
  def explain(:not_waiting), do: "That handoff isn't waiting any more."
  def explain(:nothing_to_undo), do: "There is nothing to undo for that handoff."

  def explain({:conflicts, files}),
    do: "It doesn't merge with what you have in: " <> names(files) <> "."

  def explain({:in_the_way, files}),
    do:
      "You have files of your own, ignored by git, where it adds new ones: " <>
        names(files) <> "."

  def explain(reason)
      when reason in [:not_a_folder, :not_a_repository, :not_its_top, :no_commit, :already_added],
      do: Project.explain(reason)

  def explain(reason), do: Handoff.explain(reason)

  # File names of the handoff's, which the VM chose.
  defp names(files), do: Enum.map_join(files, ", ", &Shown.text/1)
end
