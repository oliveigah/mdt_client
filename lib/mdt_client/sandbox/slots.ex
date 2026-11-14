defmodule MDTClient.Sandbox.Slots do
  @moduledoc """
  A project's worktree slots: a few fixed worktrees in the VM,
  `/work/<name>.wt/slot-1` to `slot-<n>` (`Project.slots`, 3 by default),
  that agents take one task at a time.

  A slot keeps its folder between tasks, so what git ignores (`deps`,
  `_build`, `node_modules`, `target`) stays warm, and the line that opens
  it in Zed stays the same. Each task still gets a branch of its own,
  since handoffs go by branch: a slot never holds one fixed branch.

  The slots are made with the mirror (`ensure/2`, at each of its updates):
  on no branch, at your default target branch, so each is there to open in
  Zed before any task. One whose folder went is made again then.

  Git keeps every slot's state; MDT keeps none of its own:

    * **absent** (not made yet, or its folder is gone): free, made when
      taken or at the mirror's next update;
    * **on no branch** (`mdt worktree free` detached it) and clean: free;
    * **on a task branch**: busy, until that branch's latest handoff is
      accepted or closed with nothing done in the slot since (no change,
      no newer commit). Then it is free, without MDT touching it: the next
      `mdt worktree new` takes it. The VM may be stopped when you accept,
      and the thread may still be open there;
    * **with uncommitted work**: busy, whatever its branch. Nothing here
      ever discards work: taking or freeing such a slot is refused.

  Taking a slot starts a new branch from `host/<onto>` (`take/4`, `:new`)
  or checks out an existing branch, such as one whose handoff was sent
  back after its slot went to another task (`:resume`). A busy slot is
  never switched under the thread working in it: a sent-back branch goes
  to a free slot.

  Slots are locked (`git worktree lock`): `git worktree remove` and
  `git worktree prune` leave them alone unless forced twice. Zed's
  worktree picker and thread archive remove worktrees with at most one
  `--force`, which is how earlier per-task worktrees vanished.

  Other worktrees of the project (per-task ones made before slots, or
  Zed's own) are listed apart and keep working: handoffs go from any.
  """

  alias MDTClient.Sandbox.{Handoff, Project, Shown}

  @type state :: :absent | :missing | :foreign | :clean | :dirty

  @type slot :: %{
          name: String.t(),
          path: Path.t(),
          state: state(),
          branch: String.t() | nil,
          head: String.t() | nil,
          handoff: Handoff.t() | nil,
          free?: boolean()
        }

  @type worktree :: %{
          path: Path.t(),
          branch: String.t() | nil,
          head: String.t() | nil,
          locked?: boolean(),
          missing?: boolean()
        }

  @type look :: %{
          mirror: Path.t(),
          slots: [slot()],
          others: [worktree()],
          worktrees: [worktree()],
          branch: String.t() | nil
        }

  @type error ::
          {:no_free_slot, [slot()]}
          | {:no_such_slot, String.t(), pos_integer()}
          | {:slot_busy, slot()}
          | {:not_a_slot, String.t()}
          | {:branch_exists, String.t()}
          | {:no_branch, String.t()}
          | {:checked_out, String.t(), Path.t()}
          | {:is_a_target, String.t()}
          | {:bad_task, String.t()}
          | String.t()

  @lock "MDT worktree slot: MDT keeps it. Free it with: mdt worktree free"

  # The project's worktrees, `git worktree list --porcelain`; then, after a
  # line `--`, each worktree's folder and the slots' (the mirror left out)
  # as `missing PATH`, `dirty PATH` or `clean PATH`; then, after another
  # `--`, the commit of the branch $2 when one is named and it exists.
  @look """
  m=$1 b=$2
  shift 2
  list=$(git -C "$m" worktree list --porcelain) || exit 1
  printf '%s\\n--\\n' "$list"
  { printf '%s\\n' "$list" | sed -n 's/^worktree //p'; for p in "$@"; do printf '%s\\n' "$p"; done; } |
    sort -u | while IFS= read -r p; do
      [ "$p" = "$m" ] && continue
      if [ ! -d "$p" ]; then echo "missing $p"
      elif [ -n "$(git -C "$p" status --porcelain 2>/dev/null | head -n 1)" ]; then echo "dirty $p"
      else echo "clean $p"; fi
    done
  echo "--"
  if [ -n "$b" ]; then git -C "$m" rev-parse -q --verify "refs/heads/$b" || true; fi
  """

  # Puts the slot $2 on a new branch $4 from $5 ($3 = new), or on the
  # existing branch $4 ($3 = resume). A slot whose folder is gone loses its
  # record first; git's records of other worktrees whose folders are gone
  # are pruned, as git gc would, so their branches can be checked out.
  # Uncommitted work is checked again here: it is never switched away.
  @take """
  set -e
  m=$1 p=$2 mode=$3 b=$4 start=$5 lock=$6
  git -C "$m" worktree prune
  if [ -d "$p" ]; then
    if [ -n "$(git -C "$p" status --porcelain | head -n 1)" ]; then
      echo "$p has uncommitted work." >&2
      exit 1
    fi
    if [ "$mode" = new ]; then git -C "$p" switch -q --no-track -c "$b" "$start"
    else git -C "$p" switch -q "$b"; fi
    git -C "$m" worktree lock --reason "$lock" "$p" 2>/dev/null || true
  else
    git -C "$m" worktree remove -f -f "$p" 2>/dev/null || true
    mkdir -p "$(dirname "$p")"
    if [ "$mode" = new ]; then git -C "$m" worktree add -q --no-track -b "$b" "$p" "$start"
    else git -C "$m" worktree add -q "$p" "$b"; fi
    git -C "$m" worktree lock --reason "$lock" "$p"
  fi
  """

  # Makes each slot $4… whose folder isn't there, on no branch at $2, and
  # locks it with the reason $3. A folder that is there is left alone,
  # whatever it holds. A slot whose folder went loses its record first, as
  # when it is taken.
  @make """
  set -e
  m=$1 start=$2 lock=$3
  shift 3
  for p in "$@"; do
    [ -e "$p" ] && continue
    git -C "$m" worktree remove -f -f "$p" 2>/dev/null || true
    mkdir -p "$(dirname "$p")"
    git -C "$m" worktree add -q --detach "$p" "$start"
    git -C "$m" worktree lock --reason "$lock" "$p"
  done
  """

  # Takes the slot $1 off its branch, at the same commit, unless it has
  # uncommitted work.
  @free """
  set -e
  p=$1
  if [ -n "$(git -C "$p" status --porcelain | head -n 1)" ]; then
    echo "$p has uncommitted work." >&2
    exit 1
  fi
  git -C "$p" switch -q --detach
  """

  @doc "The folder of the project's slot `name` (`slot-1`, …) in the VM."
  @spec path(Project.t(), %{root: Path.t()}, String.t()) :: Path.t()
  def path(project, guest, name), do: Path.join(Project.worktrees_path(project, guest), name)

  @doc "The names of the project's slots, in order."
  @spec names(Project.t()) :: [String.t()]
  def names(%Project{slots: count}), do: Enum.map(1..count//1, &"slot-#{&1}")

  @doc """
  Makes the project's slots that aren't there, in the VM: on no branch, at
  `host/<default target>`, so they are free and can be opened in Zed
  before any task. Run once the mirror is up to date, which has that
  branch.
  """
  @spec ensure(Project.t(), map()) :: :ok | {:error, String.t()}
  def ensure(project, guest) do
    mirror = Project.mirror_path(project, guest)
    start = "refs/remotes/host/" <> project.default_target
    paths = Enum.map(names(project), &path(project, guest, &1))

    case guest.exec.(["sh", "-c", @make, "mdt-slots", mirror, start, @lock | paths]) do
      {:ok, _} -> :ok
      {:error, text} -> {:error, "MDT couldn't make the worktree slots: " <> Shown.text(text)}
    end
  end

  @doc """
  The project's slots and other worktrees as the VM has them now, each
  slot with its branch's latest handoff (from `handoffs`, every handoff of
  the identity) and whether it is free. With `branch`, also whether that
  branch exists (`:branch`, its commit, or nil).
  """
  @spec look(Project.t(), map(), [Handoff.t()], String.t() | nil) ::
          {:ok, look()} | {:error, String.t()}
  def look(project, guest, handoffs, branch \\ nil) do
    mirror = Project.mirror_path(project, guest)
    paths = Enum.map(names(project), &path(project, guest, &1))

    case guest.exec.(["sh", "-c", @look, "mdt-slots", mirror, branch || "" | paths]) do
      {:ok, output} ->
        {:ok, read(output, project, guest, handoffs)}

      {:error, text} ->
        {:error, "MDT couldn't read the project's worktrees: " <> Shown.text(text)}
    end
  end

  defp read(output, project, guest, handoffs) do
    [list, states | rest] = String.split(output, "\n--\n") ++ ["", ""]
    mirror = Project.mirror_path(project, guest)

    states =
      for line <- String.split(states, "\n", trim: true),
          [word, path] <- [String.split(line, " ", parts: 2)],
          state = Map.get(%{"missing" => :missing, "dirty" => :dirty, "clean" => :clean}, word),
          state != nil,
          into: %{},
          do: {path, state}

    worktrees =
      list
      |> String.split("\n\n", trim: true)
      |> Enum.map(&worktree(&1, states))
      |> Enum.reject(&(&1.path in [nil, mirror]))

    registered = Map.new(worktrees, &{&1.path, &1})

    slots =
      for name <- names(project) do
        path = path(project, guest, name)
        slot(name, path, registered[path], Map.get(states, path, :missing), project, handoffs)
      end

    slot_paths = MapSet.new(slots, & &1.path)

    branch =
      case rest |> hd() |> String.trim() do
        "" -> nil
        sha -> sha
      end

    %{
      mirror: mirror,
      slots: slots,
      others: Enum.reject(worktrees, &MapSet.member?(slot_paths, &1.path)),
      worktrees: worktrees,
      branch: branch
    }
  end

  defp worktree(block, states) do
    fields = String.split(block, "\n", trim: true)

    Enum.reduce(
      fields,
      %{path: nil, branch: nil, head: nil, locked?: false, missing?: false},
      fn
        "worktree " <> path, acc ->
          %{acc | path: Shown.text(path), missing?: Map.get(states, path) == :missing}

        "HEAD " <> sha, acc ->
          %{acc | head: sha}

        "branch refs/heads/" <> branch, acc ->
          %{acc | branch: Shown.text(branch)}

        "locked" <> _, acc ->
          %{acc | locked?: true}

        _other, acc ->
          acc
      end
    )
  end

  defp slot(name, path, worktree, state, project, handoffs) do
    state =
      case {worktree, state} do
        {nil, :missing} -> :absent
        {nil, _there} -> :foreign
        {_worktree, state} -> state
      end

    branch = worktree && worktree.branch
    handoff = branch && latest_handoff(handoffs, project, branch)

    slot = %{
      name: name,
      path: path,
      state: state,
      branch: branch,
      head: worktree && worktree.head,
      handoff: handoff
    }

    Map.put(slot, :free?, free?(slot))
  end

  @doc """
  Whether a slot can take a task: absent, its folder gone, or clean and on
  no branch or on a branch whose latest handoff was accepted or closed at
  the commit it is on.
  """
  @spec free?(map()) :: boolean()
  def free?(%{state: state}) when state in [:absent, :missing], do: true
  def free?(%{state: :clean, branch: nil}), do: true

  def free?(%{state: :clean, head: head, handoff: %Handoff{status: status, head: head}})
      when status in [:accepted, :closed],
      do: true

  def free?(_slot), do: false

  @doc "The latest handoff from `branch` of the project, or nil."
  @spec latest_handoff([Handoff.t()], Project.t(), String.t()) :: Handoff.t() | nil
  def latest_handoff(handoffs, %Project{name: name}, branch) do
    handoffs
    |> Enum.filter(&(&1.project == name and &1.source.branch == branch))
    |> Enum.max_by(& &1.id, fn -> nil end)
  end

  @doc "The slot whose folder `top` is, or nil."
  @spec slot_at(look(), Path.t() | nil) :: slot() | nil
  def slot_at(%{slots: slots}, top), do: Enum.find(slots, &(&1.path == top))

  @doc """
  Takes a slot for a task, in the VM.

  `how` is `:new` (a new branch `task` from `host/<onto>`) or `:resume`
  (the existing branch `task`, as it is). `opts`:

    * `:onto`: the target branch a new branch starts from;
    * `:slot`: the slot to take, by name (`slot-2`) or number (`2`);
      otherwise the slot `:here` (the folder the agent is in) when it is
      free, else the first free one;
    * `:here`: the folder the agent is in;
    * `:handoffs`: every handoff of the identity.

  Returns the slot taken, and `:started`, `:resumed`, or `:already` when
  the branch to resume is in a slot already (nothing changes then).
  """
  @spec take(Project.t(), map(), :new | :resume, String.t(), keyword()) ::
          {:ok, slot(), :started | :resumed | :already} | {:error, error()}
  def take(project, guest, how, task, opts) do
    with true <- ref?(task) or {:error, {:bad_task, Shown.text(task)}},
         true <- task not in project.targets or {:error, {:is_a_target, task}},
         {:ok, look} <- look(project, guest, Keyword.get(opts, :handoffs, []), task),
         {:ok, slot, outcome} <- choose(look, how, task, opts) do
      case outcome do
        :already ->
          {:ok, slot, :already}

        outcome ->
          start = "refs/remotes/host/" <> Keyword.get(opts, :onto, project.default_target)
          mode = if how == :new, do: "new", else: "resume"
          mirror = Project.mirror_path(project, guest)

          case guest.exec.([
                 "sh",
                 "-c",
                 @take,
                 "mdt-slot",
                 mirror,
                 slot.path,
                 mode,
                 task,
                 start,
                 @lock
               ]) do
            {:ok, _} -> {:ok, %{slot | state: :clean, branch: task, free?: false}, outcome}
            {:error, text} -> {:error, Shown.text(text)}
          end
      end
    end
  end

  defp choose(look, :new, task, opts) do
    if look.branch,
      do: {:error, {:branch_exists, task}},
      else: with({:ok, slot} <- pick(look, opts), do: {:ok, slot, :started})
  end

  defp choose(look, :resume, task, opts) do
    held = Enum.find(look.worktrees, &(&1.branch == task))
    slot = held && slot_at(look, held.path)

    cond do
      is_nil(look.branch) ->
        {:error, {:no_branch, task}}

      slot && slot.state == :missing ->
        {:ok, slot, :resumed}

      slot ->
        {:ok, slot, :already}

      held && not held.missing? ->
        {:error, {:checked_out, task, held.path}}

      true ->
        with {:ok, slot} <- pick(look, opts), do: {:ok, slot, :resumed}
    end
  end

  defp pick(look, opts) do
    case Keyword.get(opts, :slot) do
      named when named not in [nil, ""] ->
        name = slot_name(named)

        case Enum.find(look.slots, &(&1.name == name)) do
          nil -> {:error, {:no_such_slot, Shown.text(name), length(look.slots)}}
          %{free?: true} = slot -> {:ok, slot}
          slot -> {:error, {:slot_busy, slot}}
        end

      _any ->
        here = slot_at(look, Keyword.get(opts, :here))

        case if(here && here.free?, do: here, else: Enum.find(look.slots, & &1.free?)) do
          nil -> {:error, {:no_free_slot, look.slots}}
          slot -> {:ok, slot}
        end
    end
  end

  @doc "A slot's name from what an agent typed: `2`, `slot-2` or its folder."
  @spec slot_name(term()) :: String.t()
  def slot_name(n) when is_integer(n), do: "slot-#{n}"

  def slot_name(text) when is_binary(text) do
    text = text |> String.trim() |> Path.basename()
    if text =~ ~r/\A\d+\z/, do: "slot-" <> text, else: text
  end

  def slot_name(_other), do: ""

  @doc """
  Frees a slot: takes it off its branch, which stays with all its commits,
  so the next task can take it. Refused with uncommitted work. `which` is a
  slot's name or number, or nil for the slot `here` is.
  """
  @spec free(Project.t(), map(), String.t() | nil, keyword()) ::
          {:ok, slot()} | {:error, error()}
  def free(project, guest, which, opts) do
    with {:ok, look} <- look(project, guest, Keyword.get(opts, :handoffs, [])),
         {:ok, slot} <- named_or_here(look, which, Keyword.get(opts, :here)) do
      case slot do
        %{state: state} when state in [:absent, :missing] ->
          {:ok, slot}

        %{state: :dirty} ->
          {:error, {:slot_busy, slot}}

        %{state: :foreign} ->
          {:error, {:slot_busy, slot}}

        %{branch: nil} ->
          {:ok, slot}

        slot ->
          case guest.exec.(["sh", "-c", @free, "mdt-slot", slot.path]) do
            {:ok, _} -> {:ok, slot}
            {:error, text} -> {:error, Shown.text(text)}
          end
      end
    end
  end

  defp named_or_here(look, which, here) when which in [nil, ""] do
    case slot_at(look, here) do
      nil -> {:error, {:not_a_slot, Shown.text(here || "")}}
      slot -> {:ok, slot}
    end
  end

  defp named_or_here(look, which, _here) do
    name = slot_name(which)

    case Enum.find(look.slots, &(&1.name == name)) do
      nil -> {:error, {:no_such_slot, Shown.text(name), length(look.slots)}}
      slot -> {:ok, slot}
    end
  end

  # A branch name, and nothing git or a shell would read otherwise.
  defp ref?(task) do
    task =~ ~r"\A[A-Za-z0-9][A-Za-z0-9._/-]{0,99}\z" and
      not String.contains?(task, ["..", "//", "@{"]) and
      not String.ends_with?(task, ["/", ".", ".lock"])
  end

  @doc "What a slot holds, in words: `free`, `fix-login, handoff #4 open`, …"
  @spec words(slot()) :: String.t()
  def words(%{state: :absent}), do: "free, not made yet"

  def words(%{state: :missing, branch: nil}),
    do: "free, its folder is gone; made again when taken"

  def words(%{state: :missing, branch: branch}),
    do: "free, its folder is gone (the branch #{branch} stays); made again when taken"

  def words(%{state: :foreign}),
    do: "in the way: its folder is there but isn't a worktree of the project"

  def words(%{state: :dirty, branch: branch}),
    do: "#{branch || "on no branch"}, with uncommitted work"

  def words(%{branch: nil}), do: "free"

  def words(%{branch: branch, handoff: handoff, free?: free?}) do
    held =
      case handoff do
        nil -> "#{branch}, no handoff yet"
        %Handoff{id: id, status: status} -> "#{branch}, handoff ##{id} #{status_word(status)}"
      end

    if free?, do: "free (#{held})", else: held
  end

  @doc "A handoff's status, in words."
  @spec status_word(Handoff.status()) :: String.t()
  def status_word(:open), do: "open"
  def status_word(:sent_back), do: "sent back"
  def status_word(:accepted), do: "accepted"
  def status_word(:closed), do: "closed"

  @doc "Why a slot couldn't be taken or freed, in words."
  @spec explain(error()) :: String.t()
  def explain({:no_free_slot, slots}) do
    held = Enum.map_join(slots, "\n", &"  #{&1.name}: #{words(&1)}")

    """
    No slot is free:
    #{held}
    A slot is free once its task's handoff is accepted or closed, or after mdt worktree free SLOT. Ask the user which one to free.\
    """
  end

  def explain({:no_such_slot, name, count}),
    do: "There is no slot #{name}: the project has #{count}, slot-1 to slot-#{count}."

  def explain({:slot_busy, %{state: :dirty} = slot}),
    do:
      "#{slot.name} has uncommitted work (#{slot.branch || "on no branch"}). Commit or discard it in #{slot.path} first."

  def explain({:slot_busy, %{state: :foreign} = slot}),
    do: "#{slot.path} is there but isn't a worktree of the project. Move it away, then try again."

  def explain({:slot_busy, slot}),
    do:
      "#{slot.name} holds #{words(slot)}. Once that task is done, free it with mdt worktree free #{slot.name}, or take another slot."

  def explain({:not_a_slot, _here}),
    do: "This folder isn't a slot. Name one: mdt worktree free slot-2."

  def explain({:branch_exists, task}),
    do:
      "There is a branch #{task} already. To continue it in a free slot: mdt worktree resume #{task}. For a new task, choose another name."

  def explain({:no_branch, task}),
    do: "There is no branch #{task}. Start a task on a new one with: mdt worktree new #{task}"

  def explain({:checked_out, task, path}),
    do: "#{task} is checked out in #{path}: continue it there."

  def explain({:is_a_target, task}),
    do:
      "#{task} is one of the user's target branches. Start a task from it: mdt worktree new TASK --onto #{task}"

  def explain({:bad_task, task}),
    do: "\"#{task}\" can't be a branch name. Use letters, digits, dots, dashes and slashes."

  def explain(text) when is_binary(text), do: text
end
