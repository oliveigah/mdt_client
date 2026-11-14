defmodule MDTClient.Sandbox.Handoffs do
  @moduledoc """
  The handoffs of one identity, as the agent channel and the pages use
  them: opened by agents with `mdt handoff`, accepted, sent back or closed
  by you.

  The sandbox (`MDTClient.Sandbox.Server`) keeps the records. The git work
  (in the VM, the store, your repository) runs here, in the caller's
  process, so the sandbox never waits on it. Opening one goes into the VM,
  which must be running (`MDTClient.Sandbox.Projects.guest/2`).
  """

  alias MDTClient.Sandbox.{Accept, Handoff, HandoffStore, Project, Projects, Server}

  @type error ::
          :vm_not_running
          | :not_found
          | :not_open
          | :not_accepted
          | :not_closed
          | Handoff.refusal()
          | Accept.problem()
          | String.t()

  ## What agents ask through the channel

  @doc """
  Opens a handoff from the branch the agent is on, in the folder `ask.cwd`
  in the VM, or makes a new revision of the one that branch has open.

  `ask` holds the agent's words: `cwd`, `title`, `body`, `agent`,
  `thread`, `thread_id`, and optionally `onto`, the target branch. Returns
  the handoff and whether it was `:opened` or `:updated`.
  """
  @spec open(String.t(), map()) :: {:ok, Handoff.t(), :opened | :updated} | {:error, error()}
  def open(username, ask) do
    %{projects: projects, handoffs: handoffs, vm: vm, dir: dir} = Server.call(username, :projects)
    words = Handoff.words(ask)

    with {:ok, guest} <- Projects.guest(username, vm),
         {:ok, %{source: source}} <- Handoff.look(guest, Map.get(ask, :cwd)),
         %Project{} = project <-
           Project.of_folder(projects, guest, source.folder) || {:error, :not_in_a_project},
         true <- source.top != Project.mirror_path(project, guest) or {:error, :in_the_mirror},
         existing = open_from(handoffs, source),
         onto = onto(Map.get(ask, :onto), existing, project),
         true <- onto in project.targets or {:error, {:not_a_target, onto, project.targets}},
         true <- source.branch != onto or {:error, :onto_itself},
         true <- words.title != "" or existing != nil or {:error, :no_title},
         store = HandoffStore.path(dir, project.path),
         :ok <- HandoffStore.ensure(store, project.path),
         id = if(existing, do: existing.id, else: Server.call(username, :next_handoff_id)),
         {:ok, head} <-
           HandoffStore.receive(
             store,
             guest,
             source.folder,
             source.branch,
             id,
             Handoff.size_limit_mib()
           ) do
      handoff = build(existing, id, words, project, onto, source, head)

      case Handoff.facts(store, handoff) do
        {:ok, %{conflicts: []} = facts} ->
          handoff = %{handoff | stats: Handoff.stats(facts), base_commit: facts.merge_base}
          verb = if existing, do: "updated", else: "handed off"

          {:ok, dropped} =
            Server.call(
              username,
              {:put_handoff, handoff, "#{who(handoff)} #{verb} ##{id}: \"#{handoff.title}\""}
            )

          Enum.each(dropped, &forget(dir, &1))
          {:ok, handoff, if(existing, do: :updated, else: :opened)}

        {:ok, %{conflicts: files}} ->
          # A revision that doesn't merge leaves the one before as it was.
          if existing,
            do: HandoffStore.point(store, id, existing.head),
            else: HandoffStore.drop(store, id)

          {:error, {:catch_up, onto, files}}

        {:error, _no_history} ->
          unless existing, do: HandoffStore.drop(store, id)
          {:error, :unrelated}
      end
    end
  end

  defp onto(claim, existing, project) do
    cond do
      is_binary(claim) and String.trim(claim) != "" -> String.trim(claim)
      existing -> existing.onto
      true -> project.default_target
    end
  end

  defp build(nil, id, words, project, onto, source, head) do
    now = now()

    %Handoff{
      id: id,
      title: words.title,
      body: words.body,
      agent: words.agent,
      thread: words.thread,
      thread_id: words.thread_id,
      project: project.name,
      repo: project.path,
      onto: onto,
      source: source,
      head: head,
      opened_at: now,
      updated_at: now,
      timeline: [event(:opened, "#{who(words)} handed it off")]
    }
  end

  # A new revision may come from another folder than the last: its branch
  # moved to another worktree slot.
  defp build(%Handoff{} = handoff, _id, words, _project, onto, source, head) do
    moved? = handoff.head != head

    %{
      handoff
      | title: if(words.title == "", do: handoff.title, else: words.title),
        body: if(words.body == "", do: handoff.body, else: words.body),
        agent: words.agent || handoff.agent,
        thread: words.thread || handoff.thread,
        thread_id: words.thread_id || handoff.thread_id,
        onto: onto,
        source: source,
        head: head,
        status: :open,
        updated_at: now(),
        revision: if(moved?, do: handoff.revision + 1, else: handoff.revision),
        timeline:
          handoff.timeline ++
            [
              event(
                :updated,
                if(moved?,
                  do: "#{who(words)} handed off new commits (revision #{handoff.revision + 1})",
                  else: "#{who(words)} updated it, with no new commits"
                )
              )
            ]
    }
  end

  # One handoff per branch of a repository in the VM while it is open.
  defp open_from(handoffs, source) do
    Enum.find(handoffs, fn handoff ->
      handoff.status in [:open, :sent_back] and handoff.source.folder == source.folder and
        handoff.source.branch == source.branch
    end)
  end

  @doc """
  The handoffs of the project `cwd` is in, in the VM, newest first, each
  with what MDT can say of it now; the folder `cwd` is in; and the
  project's worktrees as the VM has them now (`Projects.place/2`), to say
  where each handoff's branch is.
  """
  @spec for_agent(String.t(), String.t()) ::
          {:ok, Project.t(), [{Handoff.t(), map() | nil}], :mirror | {:worktree, String.t()},
           MDTClient.Sandbox.Slots.look() | nil}
          | {:error, error()}
  def for_agent(username, cwd) do
    %{handoffs: handoffs, dir: dir} = Server.call(username, :projects)

    with {:ok, project, where, look} <- Projects.place(username, cwd) do
      mine =
        handoffs
        |> Enum.filter(&(&1.project == project.name))
        |> Enum.sort_by(& &1.id, :desc)
        |> Enum.map(fn handoff ->
          facts =
            if handoff.status in [:open, :sent_back],
              do: ok(Handoff.facts(HandoffStore.path(dir, handoff.repo), handoff))

          {handoff, facts}
        end)

      {:ok, project, mine, where, look}
    end
  end

  ## What you do with one

  @doc "Every handoff, newest first."
  @spec list(String.t()) :: [Handoff.t()]
  def list(username), do: Enum.sort_by(Server.call(username, :projects).handoffs, & &1.id, :desc)

  @doc """
  What MDT works out about one against your repository as it is now. The
  size and conflicts the list shows are kept up to date with it.
  """
  @spec facts(String.t(), pos_integer()) :: {:ok, Handoff.facts()} | {:error, error()}
  def facts(username, id) do
    with {:ok, handoff, store} <- find(username, id),
         {:ok, facts} <- Handoff.facts(store, handoff) do
      stats = Handoff.stats(facts)

      if handoff.status in [:open, :sent_back] and stats != handoff.stats,
        do: Server.call(username, {:handoff_stats, id, stats})

      {:ok, facts}
    end
  end

  @doc "Works out again the size and conflicts of a project's open handoffs, as after your branch moved."
  @spec refresh(String.t(), String.t()) :: :ok
  def refresh(username, project) do
    for %Handoff{project: ^project, status: status, id: id} <- list(username),
        status in [:open, :sent_back],
        do: facts(username, id)

    :ok
  end

  @doc "Its change, file by file, against the commit it was built on."
  @spec diff(String.t(), pos_integer(), String.t()) :: {:ok, map()} | {:error, error()}
  def diff(username, id, merge_base) do
    with {:ok, handoff, store} <- find(username, id),
         do: Handoff.diff(store, handoff, merge_base)
  end

  @doc "What accepting it `how` would do (`Accept.preview/3`)."
  @spec preview(String.t(), pos_integer(), Accept.how()) :: {:ok, map()} | {:error, error()}
  def preview(username, id, how) do
    with {:ok, handoff, store} <- find(username, id), do: Accept.preview(store, handoff, how)
  end

  @doc "Accepts an open handoff onto its target branch (`Accept.run/4`)."
  @spec accept(String.t(), pos_integer(), Accept.how(), boolean()) ::
          {:ok, Handoff.t()} | {:error, error()}
  def accept(username, id, how, anyway? \\ false) do
    with {:ok, %Handoff{status: status} = handoff, store} <- find(username, id),
         true <- status in [:open, :sent_back] or {:error, :not_open},
         {:ok, accepted} <- Accept.run(store, handoff, how, anyway: anyway?) do
      update(username, id, "##{id} accepted", fn handoff ->
        %{
          handoff
          | status: :accepted,
            accepted: accepted,
            timeline:
              handoff.timeline ++ [event(:accepted, "You accepted " <> accepted_words(accepted))]
        }
      end)
    end
  end

  @doc "How and where a handoff was accepted, in words."
  @spec accepted_words(Handoff.accepted()) :: String.t()
  def accepted_words(%{how: :commits, branch: branch}), do: "the agent's commits onto #{branch}"

  def accepted_words(%{how: :changes, branch: branch}),
    do: "the changes onto #{branch}, uncommitted"

  @doc "Puts its commits on a new branch of yours, to look at; it stays open (`Accept.save_branch/3`)."
  @spec save_branch(String.t(), pos_integer(), String.t()) ::
          {:ok, String.t()} | {:error, error()}
  def save_branch(username, id, branch) do
    with {:ok, handoff, store} <- find(username, id),
         {:ok, branch} <- Accept.save_branch(store, handoff, branch) do
      update(username, id, "##{id} saved as #{branch}", fn handoff ->
        %{handoff | timeline: handoff.timeline ++ [event(:saved, "You saved it as #{branch}")]}
      end)

      {:ok, branch}
    end
  end

  @doc "A branch name for `save_branch/3` that your repository doesn't have."
  @spec default_branch(String.t(), pos_integer()) :: String.t() | nil
  def default_branch(username, id) do
    case find(username, id) do
      {:ok, handoff, _store} -> Accept.default_branch(handoff)
      {:error, _} -> nil
    end
  end

  @doc "Takes an accepted handoff back out, and opens it again."
  @spec undo(String.t(), pos_integer()) :: {:ok, Handoff.t()} | {:error, error()}
  def undo(username, id) do
    with {:ok, %Handoff{status: :accepted, accepted: %{} = accepted} = handoff, _store} <-
           find(username, id),
         :ok <- Accept.undo(handoff.repo, accepted) do
      update(username, id, "##{id} taken back out", fn handoff ->
        %{
          handoff
          | status: :open,
            accepted: nil,
            timeline: handoff.timeline ++ [event(:reopened, "You took it back out")]
        }
      end)
    else
      {:ok, _handoff, _store} -> {:error, :not_accepted}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Sends an open handoff back to its thread with a note, which the agent reads with `mdt handoffs`."
  @spec send_back(String.t(), pos_integer(), String.t()) ::
          {:ok, Handoff.t()} | {:error, error()}
  def send_back(username, id, note) do
    note = String.trim(note)

    with {:ok, %Handoff{status: status}, _store} <- find(username, id),
         true <- status in [:open, :sent_back] or {:error, :not_open} do
      update(username, id, "##{id} sent back", fn handoff ->
        %{
          handoff
          | status: :sent_back,
            timeline: handoff.timeline ++ [event(:sent_back, "You sent it back", %{note: note})]
        }
      end)
    end
  end

  @doc "Closes an open handoff without accepting it."
  @spec close(String.t(), pos_integer()) :: {:ok, Handoff.t()} | {:error, error()}
  def close(username, id) do
    with {:ok, %Handoff{status: status}, _store} <- find(username, id),
         true <- status in [:open, :sent_back] or {:error, :not_open} do
      update(username, id, "##{id} closed", fn handoff ->
        %{
          handoff
          | status: :closed,
            timeline: handoff.timeline ++ [event(:closed, "You closed it")]
        }
      end)
    end
  end

  @doc "Opens a closed handoff again."
  @spec reopen(String.t(), pos_integer()) :: {:ok, Handoff.t()} | {:error, error()}
  def reopen(username, id) do
    case find(username, id) do
      {:ok, %Handoff{status: :closed}, _store} ->
        update(username, id, "##{id} reopened", fn handoff ->
          %{
            handoff
            | status: :open,
              timeline: handoff.timeline ++ [event(:reopened, "You reopened it")]
          }
        end)

      {:ok, _handoff, _store} ->
        {:error, :not_closed}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp update(username, id, summary, fun),
    do: Server.call(username, {:update_handoff, id, fun, summary})

  defp find(username, id) do
    %{handoffs: handoffs, dir: dir} = Server.call(username, :projects)

    case Enum.find(handoffs, &(&1.id == id)) do
      nil -> {:error, :not_found}
      handoff -> {:ok, handoff, HandoffStore.path(dir, handoff.repo)}
    end
  end

  # What MDT kept of a handoff too old to keep.
  defp forget(dir, handoff),
    do: HandoffStore.drop(HandoffStore.path(dir, handoff.repo), handoff.id)

  defp event(kind, text, extra \\ %{}), do: Map.merge(%{at: now(), kind: kind, text: text}, extra)

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  @doc "Who handed it off, in words."
  @spec who(map()) :: String.t()
  def who(%{agent: agent}) when agent in [nil, ""], do: "An agent"
  def who(%{agent: agent}), do: agent

  defp ok({:ok, value}), do: value
  defp ok(_), do: nil

  @doc "Why something here didn't happen, in words."
  @spec explain(error()) :: String.t()
  def explain(:vm_not_running), do: "The VM isn't running."
  def explain(:not_found), do: "That handoff is gone."
  def explain(:not_open), do: "That handoff isn't open any more."
  def explain(:not_closed), do: "That handoff isn't closed."
  def explain(:not_accepted), do: "That handoff wasn't accepted, so there is nothing to undo."
  def explain(:not_in_a_project), do: Handoff.explain(:not_in_a_project)

  def explain({kind, _} = reason)
      when kind in [:conflicts, :in_the_way, :not_checked_out, :branch_taken, :bad_branch],
      do: Accept.explain(reason)

  def explain({:pending, _, _, _} = reason), do: Accept.explain(reason)

  def explain(reason) when reason in [:up_to_date, :no_identity, :nothing_to_undo, :moved],
    do: Accept.explain(reason)

  def explain(reason), do: Handoff.explain(reason)
end
