defmodule MDTClient.Sandbox.PullRequests do
  @moduledoc """
  The pull requests of one identity, as the agent channel and the pages use
  them.

  The sandbox (`MDTClient.Sandbox.Server`) keeps the records. The git work
  (into the VM, the store, your repository) runs here, in the caller's
  process, so the sandbox never waits on it.

  Opening one and sending one back with your base go into the VM, which
  must be running. Tests set `config :mdt_client,
  MDTClient.Sandbox.PullRequests, guest: guest` to put a folder in its
  place.
  """

  alias MDTClient.Sandbox.{Guest, Landing, PullRequest, PullStore, PullTarget, Server}

  @type error ::
          :vm_not_running
          | :not_found
          | :not_open
          | :not_merged
          | :not_closed
          | PullRequest.refusal()
          | PullTarget.error()
          | Landing.problem()
          | String.t()

  ## What agents ask through the channel

  @doc """
  Opens a pull request from the branch the agent is on, in the folder
  `ask.cwd` in the VM, or updates the one that branch has open.

  `ask` holds the agent's words: `cwd`, `title`, `body`, `agent`, and
  optionally `repo` (a folder on your machine) and `base` (your branch).
  Returns the pull request and whether it was `:opened` or `:updated`.
  """
  @spec open(String.t(), map()) :: {:ok, PullRequest.t(), :opened | :updated} | {:error, error()}
  def open(username, ask) do
    %{pulls: pulls, vm: vm, dir: dir, shares: shares} = Server.call(username, :pulls)
    {title, body, agent} = PullRequest.words(ask)

    with {:ok, guest} <- guest(username, vm),
         {:ok, %{source: source, remotes: remotes}} <- PullRequest.look(guest, Map.get(ask, :cwd)),
         existing = open_from(pulls, source),
         true <- title != "" or existing != nil or {:error, :no_title},
         {:ok, repo} <- target(existing, ask, source, remotes, pulls, shares),
         {:ok, base} <- base(existing, repo, Map.get(ask, :base)),
         store = PullStore.path(dir, repo),
         :ok <- PullStore.ensure(store, repo),
         id = if(existing, do: existing.id, else: Server.call(username, :next_pull_id)),
         {:ok, head} <-
           PullStore.receive(
             store,
             guest,
             source.folder,
             source.branch,
             id,
             PullRequest.size_limit_mib()
           ) do
      now = now()

      pull =
        case existing do
          nil ->
            %PullRequest{
              id: id,
              title: title,
              body: body,
              agent: agent,
              repo: repo,
              base: base,
              source: source,
              head: head,
              opened_at: now,
              updated_at: now,
              timeline: [event(:opened, "#{who(agent)} opened it")]
            }

          %PullRequest{} = pull ->
            moved? = pull.head != head

            %{
              pull
              | title: if(title == "", do: pull.title, else: title),
                body: if(body == "", do: pull.body, else: body),
                agent: agent || pull.agent,
                head: head,
                status: :open,
                updated_at: now,
                revision: if(moved?, do: pull.revision + 1, else: pull.revision),
                timeline:
                  pull.timeline ++
                    [
                      event(
                        :updated,
                        if(moved?,
                          do: "#{who(agent)} pushed new commits (revision #{pull.revision + 1})",
                          else: "#{who(agent)} updated it, with no new commits"
                        )
                      )
                    ]
            }
        end

      case PullRequest.facts(store, pull) do
        {:ok, facts} ->
          pull = %{pull | stats: PullRequest.stats(facts), base_commit: facts.merge_base}
          verb = if existing, do: "updated", else: "opened"

          {:ok, dropped} =
            Server.call(
              username,
              {:put_pull, pull, "#{who(agent)} #{verb} pull request ##{id}: \"#{pull.title}\""}
            )

          Enum.each(dropped, &forget(dir, &1))
          {:ok, pull, if(existing, do: :updated, else: :opened)}

        {:error, _no_history} ->
          unless existing, do: PullStore.drop(store, id)
          {:error, :unrelated}
      end
    end
  end

  # One pull request per branch of a repository in the VM while it is open.
  defp open_from(pulls, source) do
    Enum.find(pulls, fn pull ->
      pull.status in [:open, :changes_requested] and pull.source.folder == source.folder and
        pull.source.branch == source.branch
    end)
  end

  defp target(%PullRequest{repo: repo}, _ask, _source, _remotes, _pulls, _shares), do: {:ok, repo}

  defp target(nil, ask, source, remotes, pulls, shares) do
    known = Enum.map(pulls, & &1.repo) ++ git_tool_repositories()

    PullTarget.resolve(
      Map.get(ask, :repo),
      %{top: source.top, remotes: remotes},
      known,
      shares: shares
    )
  end

  defp base(%PullRequest{base: base}, _repo, claim) when claim in [nil, ""], do: {:ok, base}
  defp base(_existing, repo, claim), do: PullRequest.base(repo, claim)

  # The repositories open in the Git tool, which a pull request may match
  # by remote.
  defp git_tool_repositories do
    case MDTClient.Preferences.get("git_repositories") do
      paths when is_list(paths) -> Enum.filter(paths, &is_binary/1)
      _ -> []
    end
  catch
    :exit, _ -> []
  end

  @doc """
  The pull requests from the repository `cwd` is in, in the VM, newest
  first, each with what MDT can say of it now for the agent.
  """
  @spec for_agent(String.t(), String.t()) ::
          {:ok, [{PullRequest.t(), map() | nil}]} | {:error, error()}
  def for_agent(username, cwd) do
    %{pulls: pulls, vm: vm, dir: dir} = Server.call(username, :pulls)

    with {:ok, guest} <- guest(username, vm),
         {:ok, folder} <- repository(guest, cwd) do
      mine =
        pulls
        |> Enum.filter(&(&1.source.folder == folder))
        |> Enum.sort_by(& &1.id, :desc)
        |> Enum.map(fn pull ->
          facts =
            if pull.status in [:open, :changes_requested],
              do: ok(PullRequest.facts(PullStore.path(dir, pull.repo), pull))

          {pull, facts}
        end)

      {:ok, mine}
    end
  end

  # The git folder of the repository `cwd` is in, in the VM. `mdt prs`
  # only reads, so it works on any branch, or none, with changes or not.
  defp repository(guest, cwd) do
    script =
      ~s|cd "$1" 2>/dev/null && cd "$(git rev-parse --git-common-dir 2>/dev/null)" && pwd -P|

    case guest.exec.(["sh", "-c", script, "mdt-prs", if(is_binary(cwd), do: cwd, else: "")]) do
      {:ok, folder} when folder != "" -> {:ok, String.trim(folder)}
      _ -> {:error, :not_a_repository}
    end
  end

  ## What you do with one

  @doc "Every pull request, newest first."
  @spec list(String.t()) :: [PullRequest.t()]
  def list(username) do
    %{pulls: pulls} = Server.call(username, :pulls)
    Enum.sort_by(pulls, & &1.id, :desc)
  end

  @doc """
  What MDT works out about one against your repository as it is now. The
  size and conflicts the list shows are kept up to date with it.
  """
  @spec facts(String.t(), pos_integer()) :: {:ok, PullRequest.facts()} | {:error, error()}
  def facts(username, id) do
    with {:ok, pull, store} <- find(username, id),
         {:ok, facts} <- PullRequest.facts(store, pull) do
      stats = PullRequest.stats(facts)

      if pull.status in [:open, :changes_requested] and stats != pull.stats,
        do: Server.call(username, {:pull_stats, id, stats})

      {:ok, facts}
    end
  end

  @doc "Its change, file by file, against the commit it was built on."
  @spec diff(String.t(), pos_integer(), String.t()) :: {:ok, map()} | {:error, error()}
  def diff(username, id, merge_base) do
    with {:ok, pull, store} <- find(username, id), do: PullRequest.diff(store, pull, merge_base)
  end

  @doc "The worktrees of the repository it is for, and a branch name and folder for a new one."
  @spec destinations(String.t(), pos_integer()) :: {:ok, map()} | {:error, error()}
  def destinations(username, id) do
    with {:ok, pull, _store} <- find(username, id) do
      branch = Landing.default_branch(pull.repo, pull)

      {:ok,
       %{
         worktrees: Landing.worktrees(pull.repo),
         branch: branch,
         path: Landing.default_path(pull.repo, branch)
       }}
    end
  end

  @doc "What bringing it in this way would do (`Landing.preview/4`)."
  @spec preview(String.t(), pos_integer(), Landing.choice()) :: {:ok, map()} | {:error, error()}
  def preview(username, id, choice) do
    with {:ok, pull, store} <- find(username, id),
         %{shares: shares} = Server.call(username, :pulls) do
      Landing.preview(store, pull, choice, shares: shares)
    end
  end

  @doc "Brings an open pull request in, where and how you chose (`Landing.land/4`)."
  @spec land(String.t(), pos_integer(), Landing.choice(), boolean()) ::
          {:ok, PullRequest.t()} | {:error, error()}
  def land(username, id, choice, anyway? \\ false) do
    %{shares: shares} = Server.call(username, :pulls)

    with {:ok, %PullRequest{status: status} = pull, store} <- find(username, id),
         true <- status in [:open, :changes_requested] or {:error, :not_open},
         {:ok, landed} <- Landing.land(store, pull, choice, anyway: anyway?, shares: shares) do
      update(username, id, "##{id} brought in", fn pull ->
        %{
          pull
          | status: :merged,
            landed: landed,
            timeline:
              pull.timeline ++ [event(:merged, "You brought it in: " <> landing_words(landed))]
        }
      end)
    end
  end

  @doc "Where and how a pull request was brought in, in words."
  @spec landing_words(PullRequest.landed()) :: String.t()
  def landing_words(%{how: how, branch: branch, worktree: worktree}) do
    what = if how == :changes, do: "the changes, uncommitted,", else: "the agent's commits"

    where =
      case {worktree, branch} do
        {nil, branch} -> "as the new branch #{branch}"
        {path, nil} -> "into #{path}"
        {path, branch} -> "into #{branch}, at #{path}"
      end

    "#{what} #{where}"
  end

  @doc "Takes a brought-in pull request back out, and opens it again."
  @spec undo(String.t(), pos_integer()) :: {:ok, PullRequest.t()} | {:error, error()}
  def undo(username, id) do
    with {:ok, %PullRequest{status: :merged, landed: %{} = landed} = pull, _store} <-
           find(username, id),
         :ok <- Landing.undo(pull.repo, landed) do
      update(username, id, "##{id} taken back out", fn pull ->
        %{
          pull
          | status: :open,
            landed: nil,
            timeline: pull.timeline ++ [event(:reopened, "You took it back out")]
        }
      end)
    else
      {:ok, _pull, _store} -> {:error, :not_merged}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Sends an open pull request back with a note, which the agent reads with
  `mdt prs`. With `send_base?`, your base branch goes to the VM too, as
  `host/<base>` in the repository it came from, for the agent to merge.
  """
  @spec send_back(String.t(), pos_integer(), String.t(), boolean()) ::
          {:ok, PullRequest.t()} | {:error, error()}
  def send_back(username, id, note, send_base? \\ false) do
    %{vm: vm} = Server.call(username, :pulls)
    note = String.trim(note)

    with {:ok, %PullRequest{status: status} = pull, _store} <- find(username, id),
         true <- status in [:open, :changes_requested] or {:error, :not_open},
         :ok <- if(send_base?, do: send_base(username, vm, pull), else: :ok) do
      text =
        "You sent it back" <>
          if(send_base?, do: " with your #{pull.base}, as host/#{pull.base}", else: "")

      update(username, id, "##{id} sent back", fn pull ->
        %{
          pull
          | status: :changes_requested,
            timeline:
              pull.timeline ++
                [event(:sent_back, text, %{note: note, base: send_base? && pull.base})]
        }
      end)
    end
  end

  defp send_base(username, vm, pull) do
    with {:ok, guest} <- guest(username, vm), do: Landing.send_base(pull, guest)
  end

  @doc "Closes an open pull request without bringing it in."
  @spec close(String.t(), pos_integer()) :: {:ok, PullRequest.t()} | {:error, error()}
  def close(username, id) do
    with {:ok, %PullRequest{status: status}, _store} <- find(username, id),
         true <- status in [:open, :changes_requested] or {:error, :not_open} do
      update(username, id, "##{id} closed", fn pull ->
        %{pull | status: :closed, timeline: pull.timeline ++ [event(:closed, "You closed it")]}
      end)
    end
  end

  @doc "Opens a closed pull request again."
  @spec reopen(String.t(), pos_integer()) :: {:ok, PullRequest.t()} | {:error, error()}
  def reopen(username, id) do
    with {:ok, %PullRequest{status: :closed}, _store} <- find(username, id) do
      update(username, id, "##{id} reopened", fn pull ->
        %{pull | status: :open, timeline: pull.timeline ++ [event(:reopened, "You reopened it")]}
      end)
    else
      {:ok, _pull, _store} -> {:error, :not_closed}
      {:error, reason} -> {:error, reason}
    end
  end

  defp update(username, id, summary, fun) do
    Server.call(username, {:update_pull, id, fun, summary})
  end

  defp find(username, id) do
    %{pulls: pulls, dir: dir} = Server.call(username, :pulls)

    case Enum.find(pulls, &(&1.id == id)) do
      nil -> {:error, :not_found}
      pull -> {:ok, pull, PullStore.path(dir, pull.repo)}
    end
  end

  # What MDT kept of a pull request too old to keep.
  defp forget(dir, pull), do: PullStore.drop(PullStore.path(dir, pull.repo), pull.id)

  defp guest(username, vm) do
    case Application.get_env(:mdt_client, __MODULE__, [])[:guest] do
      nil when vm.status == :running -> {:ok, Guest.vm(username, vm.name)}
      nil -> {:error, :vm_not_running}
      guest -> {:ok, guest}
    end
  end

  defp event(kind, text, extra \\ %{}), do: Map.merge(%{at: now(), kind: kind, text: text}, extra)

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp who(nil), do: "An agent"
  defp who(agent), do: agent

  defp ok({:ok, value}), do: value
  defp ok(_), do: nil

  @doc "Why something here didn't happen, in words."
  @spec explain(error()) :: String.t()
  def explain(:vm_not_running), do: "The VM isn't running."
  def explain(:not_found), do: "That pull request is gone."
  def explain(:not_open), do: "That pull request isn't open any more."
  def explain(:not_closed), do: "That pull request isn't closed."

  def explain(:not_merged),
    do: "That pull request wasn't brought in, so there is nothing to undo."

  def explain(:no_target), do: PullTarget.explain(:no_target)

  def explain({kind, _} = reason) when kind in [:not_a_repository, :no_commit, :writable],
    do: PullTarget.explain(reason)

  def explain({:refused, _folder, _what} = reason), do: PullTarget.explain(reason)

  def explain({kind, _} = reason)
      when kind in [
             :conflicts,
             :in_the_way,
             :branch_taken,
             :bad_branch,
             :path_taken,
             :bad_path,
             :path_writable
           ],
      do: Landing.explain(reason)

  def explain(reason)
      when reason in [
             :not_a_worktree,
             :needs_a_worktree,
             :worktree_detached,
             :nothing_to_undo,
             :moved
           ],
      do: Landing.explain(reason)

  def explain(reason), do: PullRequest.explain(reason)
end
