defmodule MDTClient.Sandbox.Server do
  @moduledoc """
  The agent sandbox of one unlocked identity: its grants and their values,
  the VM, the image, and every decision the proxy asks for.

  One process per unlocked identity, started by `MDTClient.Vault.Store`. Grants,
  values, settings and the CA are sealed with the vault key into
  `sandbox.bin`; approvals (agents' asks included) and activity live in
  memory.

  This module is the process: it holds the state and takes every message.
  What it does with one is in the modules next to it, each with one job on
  that state, all running here, in this process:

  | Module      | Its job                                                        |
  | ----------- | -------------------------------------------------------------- |
  | `State`     | changing the state and telling the pages, the log, saving      |
  | `Grants`    | building and checking grants, turning on, allowances, expiry   |
  | `Approvals` | what waits for you: holding, your decision, giving up          |
  | `Values`    | the real values, and answering the proxy with them             |
  | `HostRuns`  | commands on this machine: the ask, the run, its output         |
  | `Machine`   | the VM in its bubble, its disks, the image                     |

  Whether a use goes through, asks or is refused is not decided here:
  `MDTClient.Sandbox.Policy` says, from the grants, the use and the clock,
  and this process acts on the answer.

  `MDTClient.Sandbox.Egress` asks three things of it for each connection and
  request: may this destination be reached (`destination`), should this
  host be read (`intercept?`), and may this request go out with the real
  value in it (`authorize`). A use of a grant waits for you unless an
  allowance covers it: the caller is held, and answered when you decide or
  when the hold runs out.

  `MDTClient.Sandbox.Channel` brings agents' asks from the VM: for a grant
  (`request_access`), which waits for you as an activation approval, and to
  run a command on the host (`request_command`), which waits as a command
  approval. It waits on your answer (`await`) for a while before telling the
  agent to come back. An approved command runs in a task
  (`MDTClient.Sandbox.HostRun`), and its output goes back to the agent, or
  first to you when you chose to see it; `stop_command` kills it.

  Every approval waiting for you has a desktop notification while
  `desktop_notifications` is on (`MDTClient.Sandbox.DesktopNotice`); it
  closes once the approval is decided or gives up, and a command coming back
  with its output gets a new one.

  It also keeps the image's builds (the current one and the two before it),
  the copies of the VM's Home disk, the projects, their mirrors and the
  handoffs agents send, and how
  far the VM's memory was seeded and reviewed.

  Slow work (`msb`, podman, copying disks, minting tokens, git) runs outside
  this process, so the pages and the proxy never wait on it. Only
  `MDTClient.Sandbox`, `Egress`, `Channel`, `Dns`, `Projects` and `Handoffs` call this
  module.
  """

  use GenServer

  require Logger

  alias MDTClient.Accounts

  alias MDTClient.Sandbox.{
    Approval,
    Bubble,
    CertificateAuthority,
    Describe,
    Disks,
    Event,
    Grant,
    HostCommand,
    HostInfo,
    HostRun,
    Image,
    Memory,
    Msb,
    Policy,
    Handoff,
    Project,
    Projects,
    Settings,
    Shares,
    VM
  }

  alias MDTClient.Sandbox.Server.{Approvals, Grants, HostRuns, Machine, State, Values}

  alias MDTClient.Vault.Store

  @file_name "sandbox.bin"
  @poll_every 10_000
  @sweep_every 30_000
  @handoffs_kept 100
  @mirror_every 2_000
  # A mirror that failed is tried again this often, unless your branch moves.
  @mirror_retry_seconds 60
  @max_leaves 64
  @leaf_kept_seconds 7 * 24 * 3_600
  @kill_after_ms 5_000

  @doc "Starts the sandbox for one unlocked identity."
  def start_link(opts) do
    username = Keyword.fetch!(opts, :username)
    GenServer.start_link(__MODULE__, opts, name: Store.via(__MODULE__, username))
  end

  @doc false
  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :username)},
      start: {__MODULE__, :start_link, [opts]},
      # Room to stop the VM on the way out.
      shutdown: 30_000
    }
  end

  @doc "The PubSub topic of everything that changes."
  defdelegate topic(username), to: State

  @doc "The PubSub topic of the waiting count, which every page's title bar shows."
  defdelegate waiting_topic(username), to: State

  @doc "The microsandbox name of this identity's VM."
  def vm_name(username), do: "mdt-" <> String.slice(Accounts.id(username), 0, 10)

  @doc false
  def call(username, message, timeout \\ 15_000),
    do: GenServer.call(Store.via(__MODULE__, username), sealed(message), timeout)

  # A value on its way to the vault travels inside a function. A message is
  # printed in full when the process it was sent to crashes, and again when
  # its caller does; a function prints as its name and nothing else.
  # `opened/1` takes it out, here in the sandbox's own process.
  defp sealed({:create_grant, %{"value" => value} = attrs}) when is_binary(value),
    do: {:create_grant, %{attrs | "value" => fn -> value end}}

  defp sealed({:set_value, id, value}) when is_binary(value),
    do: {:set_value, id, fn -> value end}

  defp sealed(message), do: message

  @doc false
  def cast(username, message), do: GenServer.cast(Store.via(__MODULE__, username), message)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    username = Keyword.fetch!(opts, :username)
    key = Keyword.fetch!(opts, :key)
    dir = Path.join(Accounts.dir(username), "sandbox")
    path = Accounts.store_path(username, @file_name)
    File.mkdir_p!(dir)

    saved = State.restore(path, key, username)
    # The VM's disks, and the one folder of its own that stays a folder: its
    # memory, which MDT reads.
    folders = dir |> Disks.paths() |> Map.put(:optmem, Path.join(dir, "optmem"))
    File.mkdir_p!(folders.optmem)

    settings =
      struct(Settings, Map.from_struct(saved[:settings] || default_settings()))
      |> Map.update!(:containerfile, &(&1 || Image.default_containerfile()))
      |> Map.put(:optmem_path, folders.optmem)

    builds = saved[:builds] || []
    current = saved[:current]

    state = %{
      username: username,
      key: key,
      path: path,
      dir: dir,
      ca: saved[:ca] || CertificateAuthority.new(),
      grants: saved[:grants] || [],
      values: saved[:values] || %{},
      settings: settings,
      created_spec: saved[:created_spec],
      created_ref: saved[:created_ref],
      vm_record: saved[:vm_record],
      builds: builds,
      # A copy whose file is gone can't be brought back: it isn't listed.
      snapshots: Enum.filter(saved[:snapshots] || [], &Disks.snapshot?(folders, &1)),
      projects: Enum.map(saved[:projects] || [], &Project.upgrade/1),
      # project name => what its last update did; kept in memory only.
      mirror: %{},
      handoffs: saved[:handoffs] || [],
      handoff_seq: saved[:handoff_seq] || 0,
      memory: saved[:memory] || %{seed_count: nil, seeded_at: nil, reviewed: 0},
      folders: folders,
      approvals: [],
      # approval id => the stage its desktop notification was shown for
      notified: %{},
      events: [],
      waiters: %{},
      minted: %{},
      minting: %{},
      leaves: %{},
      tasks: %{},
      running: %{},
      host: %{facts: HostInfo.facts(), tools: nil, probed_at: nil, probing?: false},
      build: nil,
      vm: %VM{name: vm_name(username), msb: Msb.executable()},
      # What a VM needs from this machine, looked at once: a bubble can be
      # made, and the tools that make disks are there.
      needs: if(State.external?(), do: Machine.needs(), else: []),
      image: %{
        tag: current,
        loaded?: false,
        building?: false,
        building: nil,
        log: [],
        error: nil
      },
      proxy: %{listening?: false, error: nil, path: nil},
      flush: nil
    }

    state = State.write_inbox(state)
    if is_nil(saved[:ca]), do: State.persist(state)
    state = if State.external?(), do: State.probe_host(state), else: state
    if State.external?(), do: Machine.write_launcher(username)
    Enum.each(state.grants, &State.schedule_expiry/1)
    send(self(), :sweep)
    # After a restart of this process, the proxy tells it again how it is.
    MDTClient.Sandbox.Egress.report_again(username)

    if State.external?() do
      Process.send_after(self(), :poll, @poll_every)
      Process.send_after(self(), :mirror, @mirror_every)
      {:ok, state, {:continue, :check}}
    else
      {:ok, state}
    end
  end

  @impl true
  def handle_continue(:check, state), do: {:noreply, Machine.check(state)}

  defp default_settings, do: %Settings{cpus: max(1, div(System.schedulers_online(), 2))}

  @impl true
  def handle_call(:snapshot, _from, state) do
    {waiting, decided} = Enum.split_with(state.approvals, &(&1.status == :waiting))
    {running, history} = Enum.split_with(decided, &Approval.running?/1)

    {:reply,
     %{
       vm:
         state.vm
         |> Map.put(:stale?, Machine.stale?(state))
         |> Map.put(:record, State.vm_record(state)),
       settings: state.settings,
       grants: state.grants,
       values: Map.new(state.grants, &{&1.id, Map.has_key?(state.values, &1.id)}),
       waiting: Enum.sort_by(waiting, & &1.requested_at, DateTime),
       running: Enum.sort_by(running, & &1.run.started_at, DateTime),
       history: history,
       image: state.image,
       builds: state.builds,
       created_ref: state.created_ref,
       snapshots: Enum.sort_by(state.snapshots, & &1.taken_at, {:desc, DateTime}),
       projects: state.projects,
       mirror: state.mirror,
       handoffs: state.handoffs,
       memory: Map.put(state.memory, :host?, Memory.host_memory?()),
       folders: state.folders,
       proxy: state.proxy,
       tools: %{
         msb: Msb.executable(),
         launcher: Msb.launcher(state.username),
         podman: Image.podman?(),
         needs: state.needs
       },
       inbox: State.inbox_dir(state),
       host: Map.put(state.host, :text, State.host_text(state))
     }, state}
  end

  def handle_call(:host_text, _from, state), do: {:reply, State.host_text(state), state}

  # Which VM MDT runs, for `mdt vm` in a VM to compare itself with.
  def handle_call(:vm_record, _from, state),
    do:
      {:reply, %{name: state.vm.name, status: state.vm.status, record: State.vm_record(state)},
       state}

  def handle_call(:probe_host, _from, state) do
    if state.host.probing?,
      do: {:reply, {:error, :busy}, state},
      else: {:reply, :ok, State.probe_host(state)}
  end

  def handle_call(:waiting_count, _from, state), do: {:reply, State.waiting_count(state), state}

  def handle_call({:events, filters}, _from, state) do
    events =
      state.events
      |> State.older_than(Map.get(filters, :before))
      |> Stream.filter(&Event.matches?(&1, filters))
      |> Enum.take(Map.get(filters, :limit, 200))

    {:reply, events, state}
  end

  def handle_call(:ca_pem, _from, state), do: {:reply, State.ca_pem(state), state}

  def handle_call(:build_image, _from, %{image: %{building?: true}} = state),
    do: {:reply, {:error, :busy}, state}

  def handle_call(:build_image, _from, state) do
    cond do
      not Image.podman?() -> {:reply, {:error, :no_podman}, state}
      is_nil(Msb.executable()) -> {:reply, {:error, :no_msb}, state}
      true -> {:reply, :ok, Machine.start_build(state)}
    end
  end

  def handle_call({:start_vm, options}, _from, state) do
    cond do
      state.vm.busy ->
        {:reply, {:error, :busy}, state}

      state.needs != [] ->
        {:reply, {:error, {:needs, state.needs}}, state}

      not state.image.loaded? ->
        {:reply, {:error, :no_image}, state}

      state.vm.exists? and not Machine.stale?(state) ->
        {:reply, :ok, Machine.vm_task(state, :start, "Starting…")}

      true ->
        Machine.create(state, options, "Creating…")
    end
  end

  def handle_call(:stop_vm, _from, state) do
    if state.vm.busy,
      do: {:reply, {:error, :busy}, state},
      else: {:reply, :ok, Machine.vm_task(state, :stop, "Stopping…")}
  end

  def handle_call({:recreate_vm, options}, _from, state) do
    cond do
      state.vm.busy -> {:reply, {:error, :busy}, state}
      state.needs != [] -> {:reply, {:error, {:needs, state.needs}}, state}
      not state.image.loaded? -> {:reply, {:error, :no_image}, state}
      true -> Machine.create(state, options, "Recreating…")
    end
  end

  def handle_call({:use_build, ref}, _from, state) do
    cond do
      state.image.building? ->
        {:reply, {:error, :busy}, state}

      not Enum.any?(state.builds, &(&1.ref == ref)) ->
        {:reply, {:error, :not_found}, state}

      true ->
        state =
          state
          |> State.change(:image, &%{&1.image | tag: ref, loaded?: false})
          |> State.log(%{outcome: :vm, summary: "Image #{ref} is current again"})
          |> State.changed()

        {:reply, :ok, if(State.external?(), do: Machine.check(state), else: state)}
    end
  end

  def handle_call(:memory, _from, state) do
    from = max(state.memory.seed_count || 0, state.memory.reviewed)
    {:reply, Map.merge(state.memory, %{optmem: state.folders.optmem, from: from}), state}
  end

  def handle_call(:seed_memory, _from, state) do
    cond do
      state.vm.busy -> {:reply, {:error, :busy}, state}
      state.vm.status in [:running, :starting] -> {:reply, {:error, :running}, state}
      not Memory.host_memory?() -> {:reply, {:error, :no_memory}, state}
      true -> {:reply, :ok, Machine.seed_task(state)}
    end
  end

  def handle_call({:reviewed, upto, added}, _from, state) do
    state =
      state
      |> State.change(:memory, &%{&1.memory | reviewed: max(&1.memory.reviewed, upto)})
      |> State.changed()

    state =
      if added > 0,
        do:
          State.log(state, %{
            outcome: :vm,
            summary: "#{added} of the VM's memories added to yours"
          }),
        else: state

    {:reply, :ok, state}
  end

  def handle_call({:turn_on, id, minutes, uses}, _from, state) when uses in [:ask, :all] do
    case Enum.find(state.grants, &(&1.id == id)) do
      nil ->
        {:reply, {:error, :not_found}, state}

      grant ->
        state =
          state
          |> Grants.turn_on(grant, minutes, uses, "")
          |> Approvals.settle_activations(id, minutes, uses)

        {:reply, {:ok, Enum.find(state.grants, &(&1.id == id))}, state}
    end
  end

  def handle_call({:turn_off, id}, _from, state) do
    Grants.with_grant(state, id, fn grant ->
      {%{grant | state: :off, expires_at: nil, allowances: []}, "#{grant.name} turned off"}
    end)
  end

  def handle_call({:allow_all, id, duration}, _from, state) do
    case Enum.find(state.grants, &(&1.id == id)) do
      %Grant{kind: :command} ->
        {:reply, {:error, :every_run_asks}, state}

      %Grant{state: :on} = grant ->
        state =
          state
          |> Grants.allow(grant, :all, duration)
          |> State.log(%{
            outcome: :grant,
            summary: "#{grant.name}: every use allowed #{State.duration_words(duration)}",
            grant_id: id
          })

        {:reply, {:ok, Enum.find(state.grants, &(&1.id == id))}, state}

      %Grant{} ->
        {:reply, {:error, :off}, state}

      nil ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:revoke_allowance, id, allowance_id}, _from, state) do
    Grants.with_grant(state, id, fn grant ->
      {%{grant | allowances: Enum.reject(grant.allowances, &(&1.id == allowance_id))}, nil}
    end)
  end

  def handle_call({:create_grant, attrs}, _from, state) do
    case Grants.build_grant(attrs, state.grants) do
      {:ok, grant, value} ->
        values = if value, do: Map.put(state.values, grant.id, value), else: state.values

        state =
          %{state | values: values}
          |> State.change(:grants, &(&1.grants ++ [grant]))
          |> State.log(%{outcome: :grant, summary: "#{grant.name} added", grant_id: grant.id})
          |> State.write_inbox()
          |> Machine.sync_env([grant], [])
          |> State.changed()

        {:reply, {:ok, grant}, state}

      {:error, errors} ->
        {:reply, {:error, errors}, state}
    end
  end

  def handle_call({:set_value, id, value}, _from, state) do
    value = State.opened(value)

    case Enum.find(state.grants, &(&1.id == id)) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %Grant{source: {:minted, _}} ->
        {:reply, {:error, :minted}, state}

      grant ->
        state =
          %{state | values: Map.put(state.values, id, value)}
          |> State.change(:grants, & &1.grants)
          |> State.log(%{outcome: :grant, summary: "#{grant.name}: value replaced", grant_id: id})
          |> State.write_inbox()
          |> State.changed()

        {:reply, :ok, state}
    end
  end

  def handle_call({:delete_grant, id}, _from, state) do
    case Enum.find(state.grants, &(&1.id == id)) do
      nil ->
        {:reply, {:error, :not_found}, state}

      grant ->
        state =
          state
          |> Approvals.settle_waiting(id, :grant_off, [:activation, :request, :connection])
          |> Map.update!(:values, &Map.delete(&1, id))
          |> Map.update!(:minted, &Map.delete(&1, id))
          |> State.change(:grants, &Enum.reject(&1.grants, fn g -> g.id == id end))
          |> State.log(%{outcome: :grant, summary: "#{grant.name} removed"})
          |> State.write_inbox()
          |> Machine.sync_env([], [grant])
          |> State.changed()

        {:reply, :ok, state}
    end
  end

  def handle_call({:decide, approval_id, decision}, _from, state) do
    case Enum.find(state.approvals, &(&1.id == approval_id and &1.status == :waiting)) do
      nil ->
        {:reply, {:error, :not_waiting}, state}

      approval ->
        if Approvals.fits?(approval, decision, state),
          do: {:reply, :ok, Approvals.decide(state, approval, decision)},
          else: {:reply, {:error, :bad_decision}, state}
    end
  end

  def handle_call(:agent_grants, _from, state), do: {:reply, state.grants, state}

  def handle_call({:request_access, ask}, _from, state) do
    case Approvals.activation(state, ask) do
      {:ok, approval} ->
        {state, held} = Approvals.hold_activation(state, approval)
        {:reply, {:ok, held}, state}

      {:already_on, grant} ->
        {:reply, {:already_on, grant}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:request_command, ask}, _from, state) do
    with {:ok, grant, ask, opts} <- HostRuns.command_grant(state, ask),
         {:ok, checked} <- HostCommand.check(ask, state.settings.shares, state.grants, opts),
         {:ok, approval} <- HostRuns.command_approval(state, checked, grant) do
      {state, held} = HostRuns.hold_command(state, approval)
      {:reply, {:ok, held}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:stop_command, approval_id}, _from, state) do
    case Enum.find(state.approvals, &(&1.id == approval_id)) do
      %Approval{run: %{state: :running}} = approval ->
        state =
          state
          |> State.replace_approval(%{approval | run: %{approval.run | stopped: true}})
          |> HostRuns.stop_group(approval_id, "TERM")
          |> State.log(HostRuns.command_event(approval, "you stopped it"))

        Process.send_after(self(), {:kill_command, approval_id}, @kill_after_ms)
        {:reply, :ok, state}

      _other ->
        {:reply, {:error, :not_running}, state}
    end
  end

  def handle_call({:await, approval_id, ms}, from, state) do
    case Enum.find(state.approvals, &(&1.id == approval_id)) do
      nil ->
        {:reply, {:error, :not_found}, state}

      approval ->
        if Approval.final?(approval) do
          {:reply, {:ok, approval, State.grant_of(state, approval)}, state}
        else
          ref = make_ref()
          Process.send_after(self(), {:stop_waiting, approval_id, ref}, ms)
          {:noreply, Approvals.add_waiter(state, approval_id, {from, {:await, ref}})}
        end
    end
  end

  def handle_call({:update_settings, attrs}, _from, state) do
    case Settings.cast(state.settings, attrs) do
      {:ok, settings} ->
        state =
          state
          |> State.change(:settings, fn _ -> settings end)
          |> State.write_host()
          |> State.changed()

        {:reply, {:ok, settings}, state}

      {:error, errors} ->
        {:reply, {:error, errors}, state}
    end
  end

  ## Projects and handoffs
  #
  # The records only: the git work runs in the caller's process
  # (`MDTClient.Sandbox.Projects`, `MDTClient.Sandbox.Handoffs`), or in a
  # task for the mirrors, never here.

  def handle_call(:projects, _from, state) do
    {:reply,
     %{
       projects: state.projects,
       mirror: state.mirror,
       handoffs: state.handoffs,
       vm: %{name: state.vm.name, status: state.vm.status, started_at: state.vm.started_at},
       dir: Path.dirname(state.folders.optmem),
       shares: state.settings.shares
     }, state}
  end

  def handle_call({:add_project, %Project{} = project}, _from, state) do
    if Enum.any?(state.projects, &(&1.path == project.path or &1.name == project.name)) do
      {:reply, {:error, :already_added}, state}
    else
      {:reply, {:ok, project},
       state
       |> State.change(:projects, &(&1.projects ++ [project]))
       |> State.log(%{outcome: :project, summary: "#{project.name} is a project"})
       |> State.write_inbox()
       |> State.changed()}
    end
  end

  def handle_call({:put_project, %Project{name: name} = project, summary}, _from, state) do
    if Enum.any?(state.projects, &(&1.name == name)) do
      {:reply, {:ok, project},
       state
       |> State.change(:projects, fn state ->
         Enum.map(state.projects, &if(&1.name == name, do: project, else: &1))
       end)
       |> State.log(%{outcome: :project, summary: summary})
       |> State.changed()}
    else
      {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:remove_project, name}, _from, state) do
    case Enum.find(state.projects, &(&1.name == name)) do
      nil ->
        {:reply, {:error, :not_found}, state}

      project ->
        {:reply, {:ok, project},
         state
         |> State.change(:projects, &Enum.reject(&1.projects, fn p -> p.name == name end))
         |> State.change(:mirror, &Map.delete(&1.mirror, name))
         |> State.log(%{outcome: :project, summary: "#{name} is no longer a project"})
         |> State.write_inbox()
         |> State.changed()}
    end
  end

  # What one update of a mirror did. Logged only when it says something
  # new: a rescue, a failure, or that it works again.
  def handle_call({:mirrored, name, entry}, _from, state) do
    before = Map.get(state.mirror, name, %{})

    summary =
      cond do
        entry[:rescued] ->
          "Edits found in the mirror of #{name}, kept in the VM as #{entry.rescued}"

        entry[:error] && entry.error != before[:error] ->
          "The mirror of #{name} could not be updated: #{entry.error}"

        is_nil(entry[:error]) && before[:error] ->
          "The mirror of #{name} is current again"

        true ->
          nil
      end

    state =
      state
      |> State.change(:mirror, &Map.put(&1.mirror, name, entry))
      |> then(&if(summary, do: State.log(&1, %{outcome: :project, summary: summary}), else: &1))

    {:reply, :ok, state}
  end

  def handle_call(:next_handoff_id, _from, state) do
    id = state.handoff_seq + 1
    {:reply, id, state |> State.change(:handoff_seq, fn _ -> id end) |> State.changed()}
  end

  # A handoff, new or updated. Returns those too old to keep, for the
  # caller to let go of what the store holds for them.
  def handle_call({:put_handoff, %Handoff{id: id} = handoff, summary}, _from, state) do
    others = Enum.reject(state.handoffs, &(&1.id == id))
    {kept, dropped} = Enum.split([handoff | others], @handoffs_kept)

    {:reply, {:ok, dropped},
     state
     |> State.change(:handoffs, fn _ -> kept end)
     |> State.log(%{outcome: :handoff, summary: summary})
     |> State.changed()}
  end

  # What the list shows of one, worked out again: nothing to log.
  def handle_call({:handoff_stats, id, stats}, _from, state) do
    {:reply, :ok,
     state
     |> State.change(:handoffs, fn state ->
       Enum.map(state.handoffs, &if(&1.id == id, do: %{&1 | stats: stats}, else: &1))
     end)
     |> State.changed()}
  end

  def handle_call({:update_handoff, id, fun, summary}, _from, state) do
    case Enum.find(state.handoffs, &(&1.id == id)) do
      nil ->
        {:reply, {:error, :not_found}, state}

      handoff ->
        updated = fun.(handoff)

        {:reply, {:ok, updated},
         state
         |> State.change(:handoffs, fn state ->
           Enum.map(state.handoffs, &if(&1.id == id, do: updated, else: &1))
         end)
         |> State.log(%{outcome: :handoff, summary: summary})
         |> State.changed()}
    end
  end

  def handle_call({:add_share, path, mode}, _from, state) do
    case Shares.validate(path, mode, state.settings.shares) do
      {:ok, share} ->
        settings = %{state.settings | shares: state.settings.shares ++ [share]}

        {:reply, {:ok, share},
         state
         |> State.change(:settings, fn _ -> settings end)
         |> State.write_host()
         |> State.changed()}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:remove_share, path}, _from, state) do
    settings = %{state.settings | shares: Enum.reject(state.settings.shares, &(&1.path == path))}

    {:reply, :ok,
     state
     |> State.change(:settings, fn _ -> settings end)
     |> State.write_host()
     |> State.changed()}
  end

  def handle_call({:set_share_mode, path, mode}, _from, state) when mode in [:rw, :ro] do
    shares =
      Enum.map(state.settings.shares, &if(&1.path == path, do: %{&1 | mode: mode}, else: &1))

    settings = %{state.settings | shares: shares}

    {:reply, :ok,
     state
     |> State.change(:settings, fn _ -> settings end)
     |> State.write_host()
     |> State.changed()}
  end

  def handle_call({:destination, ip, port}, from, state) do
    address = "#{:inet.ntoa(ip)}"

    case Policy.decide(Policy.snapshot(state.grants), {:connection, ip, port}, State.now()) do
      :pass ->
        {:reply, :ok, state}

      {:refuse, reason} ->
        summary =
          if reason == :reserved,
            do: "This machine or a reserved address · always refused",
            else: "Private address with no network grant on"

        state =
          State.log(state, %{outcome: :blocked, summary: summary, host: address, port: port})

        {:reply, {:deny, summary}, state}

      {:allow, grant, _allowance, _about} ->
        {:reply, :ok, State.used(state, grant.id)}

      {:ask, grant, about} ->
        approval = %Approval{
          id: "approval-" <> State.unique(),
          grant_id: grant.id,
          kind: :connection,
          title: "Connect to #{about.pattern}",
          host: address,
          pattern: about.pattern,
          join: about.pattern,
          requested_at: State.now(),
          deadline: DateTime.add(State.now(), state.settings.hold_seconds, :second),
          facts: [
            {"Destination", about.pattern},
            {"Listed as", about.listed_as},
            {"Grant", grant.name}
          ]
        }

        {:noreply, Approvals.hold(state, approval, {from, :connection})}
    end
  end

  def handle_call({:intercept?, host}, _from, state),
    do: {:reply, Policy.reads?(state.grants, host), state}

  # One certificate per name on it, kept while it is young: a leaf lasts 30
  # days and MDT can run longer. The names are few (`leaf_name/2`), and the
  # cap holds whatever else happens.
  def handle_call({:leaf, host}, _from, state) do
    name = leaf_name(state.grants, host)
    now = System.system_time(:second)

    case state.leaves do
      %{^name => {options, made}} when now - made < @leaf_kept_seconds ->
        {:reply, options, state}

      leaves ->
        options =
          state.ca |> CertificateAuthority.leaf(name) |> CertificateAuthority.ssl_options()

        leaves = if map_size(leaves) >= @max_leaves, do: %{}, else: leaves
        {:reply, options, %{state | leaves: Map.put(leaves, name, {options, now})}}
    end
  end

  def handle_call({:authorize, request}, from, state) do
    case Policy.decide(Policy.snapshot(state.grants), {:request, request}, State.now()) do
      :pass ->
        state =
          State.log(state, %{
            outcome: :tunnel,
            summary: "Read by MDT, no credential in it",
            host: request.host,
            port: 443,
            method: request.method,
            path: request.path
          })

        {:reply, {:forward, request.headers, []}, state}

      {:refuse, :multiple_grants} ->
        {:reply,
         Values.deny(
           403,
           "mdt_multiple_grants",
           "One request may carry one grant's placeholder.",
           nil
         ), state}

      {:refuse, {:wrong_host, grant}} ->
        summary = "#{grant.name} placeholder sent to #{request.host} · blocked"
        state = State.log(state, Values.request_event(request, grant, :violation, summary))

        {:reply,
         Values.deny(
           403,
           "mdt_placeholder_blocked",
           "#{grant.name} may not go to #{request.host}.",
           grant
         ), state}

      {:refuse, {:grant_off, grant}} ->
        title = Describe.request(request).title

        state =
          State.log(
            state,
            Values.request_event(request, grant, :refused, "#{title} · #{grant.name} is off")
          )

        {:reply,
         Values.deny(
           403,
           "mdt_grant_off",
           "#{grant.name} is off. Ask for it with: mdt request #{grant.id} --reason \"...\"",
           grant
         ), state}

      {:allow, grant, allowance, about} ->
        why =
          if allowance.pattern == :all,
            do: "every use allowed",
            else: "allowed like an earlier one"

        state =
          State.log(
            state,
            Values.request_event(request, grant, :swapped, "#{about.title} · #{why}")
          )

        {:noreply, Values.forward(state, grant, request, from)}

      {:ask, grant, about} ->
        approval = %Approval{
          id: "approval-" <> State.unique(),
          grant_id: grant.id,
          kind: :request,
          title: about.title,
          method: request.method,
          host: request.host,
          path: request.path,
          pattern: about.pattern,
          join: Approvals.request_digest(request),
          request: request,
          requested_at: State.now(),
          deadline: DateTime.add(State.now(), state.settings.hold_seconds, :second),
          facts: about.facts,
          claims: about.claims
        }

        {:noreply, Approvals.hold(state, approval, {from, {:request, request}})}
    end
  end

  @impl true
  def handle_cast({:log, attrs}, state), do: {:noreply, State.log(state, attrs)}

  def handle_cast({:proxy, status}, state) do
    {:noreply, State.change(state, :proxy, fn _ -> status end)}
  end

  # While the VM runs, each mirror follows your branches: the task looks at
  # them, and updates the mirrors whose branches moved.
  @impl true
  def handle_info(:mirror, state) do
    Process.send_after(self(), :mirror, @mirror_every)

    if state.vm.status == :running and state.projects != [] and
         :mirror not in Map.values(state.tasks) do
      %{username: username, projects: projects, mirror: mirror} = state
      shares = state.settings.shares
      vm = %{name: state.vm.name, status: state.vm.status, started_at: state.vm.started_at}

      {:noreply,
       State.task(state, :mirror, fn ->
         Projects.follow(username, projects, mirror, vm, @mirror_retry_seconds, shares)
       end)}
    else
      {:noreply, state}
    end
  end

  def handle_info(:poll, state) do
    Process.send_after(self(), :poll, @poll_every)

    if state.vm.busy != nil or Enum.any?(Map.values(state.tasks), &(&1 == :check)),
      do: {:noreply, state},
      else: {:noreply, Machine.check(state)}
  end

  # The timers only say when to look: what has ended is read from the clock
  # (`sweep/1`), as every decision does (`Grant.on?/2`, `Allowance.covers?/3`).
  def handle_info({:expire_grant, _id, _expires_at}, state), do: {:noreply, Grants.sweep(state)}

  def handle_info({:expire_allowance, _id, _allowance_id}, state),
    do: {:noreply, Grants.sweep(state)}

  # Timers stand still while the machine sleeps, and a wall clock can be set
  # back: looking again every so often keeps what is shown right.
  def handle_info(:sweep, state) do
    Process.send_after(self(), :sweep, @sweep_every)
    {:noreply, Grants.sweep(state)}
  end

  # Each timer names the deadline it was set for: a command waiting a second
  # time, with its output, has a later one, which its first timer must not
  # end.
  def handle_info({:give_up, approval_id, deadline}, state) do
    case Enum.find(state.approvals, &(&1.id == approval_id and &1.status == :waiting)) do
      %Approval{deadline: ^deadline} = approval -> {:noreply, Approvals.give_up(state, approval)}
      _settled_or_moved -> {:noreply, state}
    end
  end

  def handle_info({:command_started, approval_id, group}, state) do
    case state.running do
      %{^approval_id => :stop} ->
        HostRun.stop(group, "TERM")
        Process.send_after(self(), {:kill_command, approval_id}, @kill_after_ms)
        {:noreply, put_in(state.running[approval_id], group)}

      _ ->
        {:noreply, put_in(state.running[approval_id], group)}
    end
  end

  # Stopping sent TERM; whatever still runs gets KILL.
  def handle_info({:kill_command, approval_id}, state),
    do: {:noreply, HostRuns.stop_group(state, approval_id, "KILL")}

  # An agent waited as long as it said it would: it hears "still waiting",
  # and the ask stays for you.
  def handle_info({:stop_waiting, approval_id, ref}, state) do
    {mine, others} =
      state.waiters
      |> Map.get(approval_id, [])
      |> Enum.split_with(&match?({_from, {:await, ^ref}}, &1))

    approval = Enum.find(state.approvals, &(&1.id == approval_id))
    Enum.each(mine, fn {from, _} -> GenServer.reply(from, {:pending, approval}) end)

    waiters =
      if others == [],
        do: Map.delete(state.waiters, approval_id),
        else: Map.put(state.waiters, approval_id, others)

    {:noreply, %{state | waiters: waiters}}
  end

  def handle_info(:flush, state) do
    :ok = State.persist(state)
    {:noreply, %{state | flush: nil}}
  end

  def handle_info({port, {:data, {_eol, line}}}, %{build: port} = state) do
    {:noreply, Machine.build_line(state, line)}
  end

  def handle_info({port, {:exit_status, status}}, %{build: port} = state) do
    state = %{state | build: nil}

    state =
      if status == 0 do
        Machine.built(state, Image.read_build(Machine.build_dir(state), state.image.building))
      else
        state
        |> State.change(
          :image,
          &%{
            &1.image
            | building?: false,
              building: nil,
              error: "The build failed (exit #{status}). See the log."
          }
        )
        |> State.log(%{outcome: :vm, summary: "Image build failed"})
      end

    {:noreply, state}
  end

  def handle_info({ref, result}, state) when is_map_key(state.tasks, ref) do
    Process.demonitor(ref, [:flush])
    {purpose, tasks} = Map.pop(state.tasks, ref)
    {:noreply, Machine.finished(%{state | tasks: tasks}, purpose, result)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state)
      when is_map_key(state.tasks, ref) do
    {purpose, tasks} = Map.pop(state.tasks, ref)

    {:noreply,
     Machine.finished(%{state | tasks: tasks}, purpose, {:error, "crashed: #{inspect(reason)}"})}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  # Crash reports print the state; the vault key, real values, minted
  # tokens, private keys and commands' output must never reach a log.
  @impl true
  def format_status(status) do
    Map.update(status, :state, nil, fn
      %{} = state ->
        state
        |> Map.replace(:key, :redacted)
        |> Map.replace(
          :values,
          Map.new(Map.get(state, :values, %{}), fn {id, _} -> {id, :redacted} end)
        )
        |> Map.replace(:minted, :redacted)
        |> Map.replace(:minting, :redacted)
        |> Map.replace(:leaves, :redacted)
        |> Map.replace(:ca, :redacted)
        |> Map.replace(:waiters, :redacted)
        |> Map.replace(:approvals, Enum.map(Map.get(state, :approvals, []), &redact_output/1))

      other ->
        other
    end)
  end

  # A command's output can hold anything it printed, secrets included.
  defp redact_output(%Approval{run: %{output: _} = run} = approval),
    do: %{approval | run: %{run | output: :redacted}}

  defp redact_output(approval), do: approval

  @impl true
  def terminate(reason, state) do
    State.persist(state)

    # A command reports back to this process, which is going away.
    for {_id, group} <- state.running, is_integer(group), do: HostRun.stop(group, "KILL")

    # Locking MDT or quitting it leaves no VM running without the proxy. A
    # crash leaves the VM alone: the proxy is a process of its own and keeps
    # going, and the restarted sandbox finds the VM running and takes it back
    # (`check/1`), so a bug costs the agents their pending asks, not their VM.
    # If the restarts give up, the vault locks and the proxy closes with it:
    # the VM has no internet until an unlock takes it back.
    if deliberate?(reason) and state.vm.exists? and state.vm.status in [:running, :starting] do
      Bubble.stop(state.username, 30)
    end

    :ok
  end

  defp deliberate?(:normal), do: true

  defp deliberate?(:shutdown), do: true

  defp deliberate?({:shutdown, _detail}), do: true

  defp deliberate?(_crash), do: false

  # The name a certificate for `host` carries. A grant host such as
  # `*.googleapis.com` covers every name one label below it with a single
  # wildcard certificate, as TLS reads wildcards; any other name gets its
  # own.
  defp leaf_name(grants, host) do
    host = String.downcase(host)

    Enum.find_value(grants, host, fn
      %Grant{kind: :token, hosts: hosts} ->
        Enum.find(hosts, fn
          "*." <> suffix ->
            String.ends_with?(host, "." <> suffix) and
              not String.contains?(String.trim_trailing(host, "." <> suffix), ".")

          _exact ->
            false
        end)

      _other ->
        nil
    end)
  end
end
