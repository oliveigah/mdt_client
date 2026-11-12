defmodule MDTClient.Sandbox.Server do
  @moduledoc """
  The agent sandbox of one unlocked identity: its grants and their values,
  the VM, the image, and every decision the proxy asks for.

  One process per unlocked identity, started by `MDTClient.Vault.Store`. Grants,
  values, settings and the CA are sealed with the vault key into
  `sandbox.bin`; approvals (agents' asks included) and activity live in
  memory.

  `MDTClient.Sandbox.Egress` asks three things of it for each connection and
  request: may this destination be reached (`destination/3`), should this
  host be read (`intercept?/2`), and may this request go out with the real
  value in it (`authorize/2`). A use of a grant waits for you unless an
  allowance covers it: the caller is held, and answered when you decide or
  when the hold runs out.

  `MDTClient.Sandbox.Channel` brings agents' asks from the VM
  (`request_access`), which wait for you as activation approvals, and waits
  on your answer (`await`) for a while before telling the agent to come back.

  It also keeps the image's builds (the current one and the two before it),
  the snapshots of the VM's Home, and how far the VM's memory was seeded and
  reviewed. Creating or starting the VM prepares its folders first
  (`MDTClient.Sandbox.Folders`, `MDTClient.Sandbox.Memory`,
  `MDTClient.Sandbox.Instructions`).

  Slow work (`msb`, podman, copying folders, minting tokens) runs outside this
  process, so the pages and the proxy never wait on it. Only `MDTClient.Sandbox` and `Egress`
  call this module.
  """

  use GenServer

  require Logger

  alias MDTClient.Accounts

  alias MDTClient.Sandbox.{
    Allowance,
    Approval,
    Build,
    CertificateAuthority,
    Channel,
    Describe,
    Destinations,
    Event,
    Folders,
    Grant,
    Image,
    Inbox,
    Instructions,
    Memory,
    Msb,
    Presets,
    Settings,
    Shares,
    Snapshot,
    VM
  }

  alias MDTClient.Vault
  alias MDTClient.Vault.Store

  @file_name "sandbox.bin"
  @flush_after 250
  @history_limit 100
  @event_limit 1_000
  @poll_every 10_000
  @mint_fresh_ms 10 * 60_000
  @build_log_limit 400
  # An agent's ask waits this long for you; the agent itself waits less and
  # comes back with `mdt wait`.
  @activation_hold_seconds 30 * 60
  @max_waiting_activations 10
  @tasks MDTClient.Sandbox.TaskSupervisor

  ## Client

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
  def topic(username), do: "sandbox:" <> Accounts.id(username)

  @doc "The PubSub topic of the waiting count, which every page's title bar shows."
  def waiting_topic(username), do: "sandbox-waiting:" <> Accounts.id(username)

  @doc "The microsandbox name of this identity's VM."
  def vm_name(username), do: "mdt-" <> String.slice(Accounts.id(username), 0, 10)

  @doc false
  def call(username, message, timeout \\ 15_000),
    do: GenServer.call(Store.via(__MODULE__, username), message, timeout)

  @doc false
  def cast(username, message), do: GenServer.cast(Store.via(__MODULE__, username), message)

  ## Server

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    username = Keyword.fetch!(opts, :username)
    key = Keyword.fetch!(opts, :key)
    dir = Path.join(Accounts.dir(username), "sandbox")
    path = Accounts.store_path(username, @file_name)
    File.mkdir_p!(dir)

    saved = restore(path, key, username)
    folders = Folders.paths(dir)
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
      builds: builds,
      snapshots: saved[:snapshots] || [],
      memory: saved[:memory] || %{seed_count: nil, seeded_at: nil, reviewed: 0},
      folders: folders,
      approvals: [],
      events: [],
      waiters: %{},
      minted: %{},
      minting: %{},
      leaves: %{},
      tasks: %{},
      build: nil,
      vm: %VM{name: vm_name(username), msb: Msb.executable()},
      image: %{
        tag: current,
        loaded?: false,
        building?: false,
        building: nil,
        log: [],
        error: nil
      },
      proxy: %{listening?: false, error: nil, port: nil},
      flush: nil
    }

    state = write_inbox(state)
    if is_nil(saved[:ca]), do: persist(state)
    Enum.each(state.grants, &schedule_expiry/1)
    # After a restart of this process, the proxy tells it again how it is.
    MDTClient.Sandbox.Egress.report_again(username)

    if external?() do
      Process.send_after(self(), :poll, @poll_every)
      {:ok, state, {:continue, :check}}
    else
      {:ok, state}
    end
  end

  @impl true
  def handle_continue(:check, state), do: {:noreply, check(state)}

  # Tests run without touching microsandbox.
  defp external?,
    do: Keyword.get(Application.get_env(:mdt_client, __MODULE__, []), :external, true)

  defp default_settings do
    config = Application.get_env(:mdt_client, __MODULE__, [])

    %Settings{
      cpus: max(1, div(System.schedulers_online(), 2)),
      proxy_port: Keyword.get(config, :proxy_port, 18080)
    }
  end

  ## Reading

  @impl true
  def handle_call(:snapshot, _from, state) do
    {waiting, history} = Enum.split_with(state.approvals, &(&1.status == :waiting))

    {:reply,
     %{
       vm: %{state.vm | stale?: stale?(state)},
       settings: state.settings,
       grants: state.grants,
       values: Map.new(state.grants, &{&1.id, Map.has_key?(state.values, &1.id)}),
       waiting: Enum.sort_by(waiting, & &1.requested_at, DateTime),
       history: history,
       image: state.image,
       builds: state.builds,
       created_ref: state.created_ref,
       snapshots: Enum.sort_by(state.snapshots, & &1.taken_at, {:desc, DateTime}),
       memory: Map.put(state.memory, :host?, Memory.host_memory?()),
       folders: state.folders,
       proxy: Map.update!(state.proxy, :port, &(&1 || state.settings.proxy_port)),
       tools: %{msb: Msb.executable(), podman: Image.podman?()},
       inbox: inbox_dir(state)
     }, state}
  end

  def handle_call(:waiting_count, _from, state), do: {:reply, waiting_count(state), state}

  def handle_call({:events, filters}, _from, state) do
    events =
      state.events
      |> Enum.filter(&Event.matches?(&1, filters))
      |> Enum.take(Map.get(filters, :limit, 200))

    {:reply, events, state}
  end

  def handle_call(:proxy_port, _from, state), do: {:reply, state.settings.proxy_port, state}

  def handle_call(:ca_pem, _from, state), do: {:reply, ca_pem(state), state}

  ## The VM and its image

  def handle_call(:build_image, _from, %{image: %{building?: true}} = state),
    do: {:reply, {:error, :busy}, state}

  def handle_call(:build_image, _from, state) do
    cond do
      not Image.podman?() -> {:reply, {:error, :no_podman}, state}
      is_nil(Msb.executable()) -> {:reply, {:error, :no_msb}, state}
      true -> {:reply, :ok, start_build(state)}
    end
  end

  def handle_call({:start_vm, options}, _from, state) do
    cond do
      state.vm.busy ->
        {:reply, {:error, :busy}, state}

      not state.image.loaded? ->
        {:reply, {:error, :no_image}, state}

      state.vm.exists? and not stale?(state) ->
        {:reply, :ok, vm_task(state, :start, "Starting…")}

      true ->
        create(state, options, "Creating…")
    end
  end

  def handle_call(:stop_vm, _from, state) do
    if state.vm.busy,
      do: {:reply, {:error, :busy}, state},
      else: {:reply, :ok, vm_task(state, :stop, "Stopping…")}
  end

  def handle_call({:recreate_vm, options}, _from, state) do
    cond do
      state.vm.busy -> {:reply, {:error, :busy}, state}
      not state.image.loaded? -> {:reply, {:error, :no_image}, state}
      true -> create(state, options, "Recreating…")
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
          |> change(:image, &%{&1.image | tag: ref, loaded?: false})
          |> log(%{outcome: :vm, summary: "Image #{ref} is current again"})
          |> changed()

        {:reply, :ok, if(external?(), do: check(state), else: state)}
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
      true -> {:reply, :ok, seed_task(state)}
    end
  end

  def handle_call({:reviewed, upto, added}, _from, state) do
    state =
      state
      |> change(:memory, &%{&1.memory | reviewed: max(&1.memory.reviewed, upto)})
      |> changed()

    state =
      if added > 0,
        do: log(state, %{outcome: :vm, summary: "#{added} of the VM's memories added to yours"}),
        else: state

    {:reply, :ok, state}
  end

  ## Grants

  def handle_call({:turn_on, id, minutes, uses}, _from, state) when uses in [:ask, :all] do
    case Enum.find(state.grants, &(&1.id == id)) do
      nil ->
        {:reply, {:error, :not_found}, state}

      grant ->
        state =
          state |> turn_on(grant, minutes, uses, "") |> settle_activations(id, minutes, uses)

        {:reply, {:ok, Enum.find(state.grants, &(&1.id == id))}, state}
    end
  end

  def handle_call({:turn_off, id}, _from, state) do
    with_grant(state, id, fn grant ->
      {%{grant | state: :off, expires_at: nil, allowances: []}, "#{grant.name} turned off"}
    end)
  end

  def handle_call({:allow_all, id, duration}, _from, state) do
    case Enum.find(state.grants, &(&1.id == id)) do
      %Grant{state: :on} = grant ->
        state =
          state
          |> allow(grant, :all, duration)
          |> log(%{
            outcome: :grant,
            summary: "#{grant.name}: every use allowed #{duration_words(duration)}",
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
    with_grant(state, id, fn grant ->
      {%{grant | allowances: Enum.reject(grant.allowances, &(&1.id == allowance_id))}, nil}
    end)
  end

  def handle_call({:create_grant, attrs}, _from, state) do
    case build_grant(attrs, state.grants) do
      {:ok, grant, value} ->
        values = if value, do: Map.put(state.values, grant.id, value), else: state.values

        state =
          %{state | values: values}
          |> change(:grants, &(&1.grants ++ [grant]))
          |> log(%{outcome: :grant, summary: "#{grant.name} added", grant_id: grant.id})
          |> write_inbox()
          |> sync_env([grant], [])
          |> changed()

        {:reply, {:ok, grant}, state}

      {:error, errors} ->
        {:reply, {:error, errors}, state}
    end
  end

  def handle_call({:set_value, id, value}, _from, state) do
    case Enum.find(state.grants, &(&1.id == id)) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %Grant{source: {:minted, _}} ->
        {:reply, {:error, :minted}, state}

      grant ->
        state =
          %{state | values: Map.put(state.values, id, value)}
          |> change(:grants, & &1.grants)
          |> log(%{outcome: :grant, summary: "#{grant.name}: value replaced", grant_id: id})
          |> write_inbox()
          |> changed()

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
          |> settle_waiting(id, :grant_off, [:activation, :request, :connection])
          |> Map.update!(:values, &Map.delete(&1, id))
          |> Map.update!(:minted, &Map.delete(&1, id))
          |> change(:grants, &Enum.reject(&1.grants, fn g -> g.id == id end))
          |> log(%{outcome: :grant, summary: "#{grant.name} removed"})
          |> write_inbox()
          |> sync_env([], [grant])
          |> changed()

        {:reply, :ok, state}
    end
  end

  ## Decisions

  def handle_call({:decide, approval_id, decision}, _from, state) do
    case Enum.find(state.approvals, &(&1.id == approval_id and &1.status == :waiting)) do
      nil ->
        {:reply, {:error, :not_waiting}, state}

      approval ->
        if fits?(approval, decision, state),
          do: {:reply, :ok, decide(state, approval, decision)},
          else: {:reply, {:error, :bad_decision}, state}
    end
  end

  ## Agents asking, through the channel

  def handle_call(:agent_grants, _from, state), do: {:reply, state.grants, state}

  def handle_call({:request_access, ask}, _from, state) do
    case activation(state, ask) do
      {:ok, approval} ->
        {state, held} = hold_activation(state, approval)
        {:reply, {:ok, held}, state}

      {:already_on, grant} ->
        {:reply, {:already_on, grant}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:await, approval_id, ms}, from, state) do
    case Enum.find(state.approvals, &(&1.id == approval_id)) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %Approval{status: :waiting} ->
        ref = make_ref()
        Process.send_after(self(), {:stop_waiting, approval_id, ref}, ms)
        {:noreply, add_waiter(state, approval_id, {from, {:await, ref}})}

      approval ->
        {:reply, {:ok, approval, grant_of(state, approval)}, state}
    end
  end

  ## Settings

  def handle_call({:update_settings, attrs}, _from, state) do
    case cast_settings(state.settings, attrs) do
      {:ok, settings} ->
        port_changed? = settings.proxy_port != state.settings.proxy_port
        state = state |> change(:settings, fn _ -> settings end) |> changed()
        if port_changed?, do: MDTClient.Sandbox.Egress.rebind(state.username)
        {:reply, {:ok, settings}, state}

      {:error, errors} ->
        {:reply, {:error, errors}, state}
    end
  end

  def handle_call({:add_share, path, mode}, _from, state) do
    case Shares.validate(path, mode, state.settings.shares) do
      {:ok, share} ->
        settings = %{state.settings | shares: state.settings.shares ++ [share]}
        {:reply, {:ok, share}, state |> change(:settings, fn _ -> settings end) |> changed()}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:remove_share, path}, _from, state) do
    settings = %{state.settings | shares: Enum.reject(state.settings.shares, &(&1.path == path))}
    {:reply, :ok, state |> change(:settings, fn _ -> settings end) |> changed()}
  end

  def handle_call({:set_share_mode, path, mode}, _from, state) when mode in [:rw, :ro] do
    shares =
      Enum.map(state.settings.shares, &if(&1.path == path, do: %{&1 | mode: mode}, else: &1))

    settings = %{state.settings | shares: shares}
    {:reply, :ok, state |> change(:settings, fn _ -> settings end) |> changed()}
  end

  ## The proxy's questions

  def handle_call({:destination, ip, port}, from, state) do
    case Destinations.classify(ip) do
      :public ->
        {:reply, :ok, state}

      class ->
        network = for %Grant{kind: :network} = grant <- state.grants, do: {grant, specs(grant)}

        covering =
          Enum.find(network, fn {grant, specs} ->
            Grant.on?(grant) and
              Enum.any?(specs, fn spec ->
                Destinations.matches?(spec, ip, port) and
                  (class == :private or Destinations.exact?(spec, ip))
              end)
          end)

        address = "#{:inet.ntoa(ip)}"
        pattern = "#{address}:#{port}"

        case covering do
          nil ->
            summary =
              if class == :refused,
                do: "This machine or a reserved address · always refused",
                else: "Private address with no network grant on"

            state = log(state, %{outcome: :blocked, summary: summary, host: address, port: port})
            {:reply, {:deny, summary}, state}

          {grant, specs} ->
            if Enum.any?(grant.allowances, &Allowance.covers?(&1, pattern)) do
              {:reply, :ok, used(state, grant.id)}
            else
              matched = Enum.find(specs, &Destinations.matches?(&1, ip, port))

              approval = %Approval{
                id: "approval-" <> unique(),
                grant_id: grant.id,
                kind: :connection,
                title: "Connect to #{pattern}",
                host: address,
                pattern: pattern,
                requested_at: now(),
                deadline: DateTime.add(now(), state.settings.hold_seconds, :second),
                facts:
                  [{"Destination", pattern}] ++
                    if(matched, do: [{"Listed as", matched.source}], else: []) ++
                    [{"Grant", grant.name}]
              }

              {:noreply, hold(state, approval, {from, :connection})}
            end
        end
    end
  end

  def handle_call({:intercept?, host}, _from, state) do
    {:reply, Enum.any?(state.grants, &(&1.kind == :token and host_allowed?(host, &1.hosts))),
     state}
  end

  def handle_call({:leaf, host}, _from, state) do
    case state.leaves do
      %{^host => options} ->
        {:reply, options, state}

      leaves ->
        options =
          state.ca |> CertificateAuthority.leaf(host) |> CertificateAuthority.ssl_options()

        {:reply, options, %{state | leaves: Map.put(leaves, host, options)}}
    end
  end

  def handle_call({:authorize, request}, from, state) do
    found =
      for %Grant{kind: :token} = grant <- state.grants,
          carries?(request.headers, grant.placeholder),
          do: grant

    case found do
      [] ->
        state =
          log(state, %{
            outcome: :tunnel,
            summary: "Read by MDT, no credential in it",
            host: request.host,
            port: 443,
            method: request.method,
            path: request.path
          })

        {:reply, {:forward, request.headers, []}, state}

      [_, _ | _] ->
        {:reply,
         deny(403, "mdt_multiple_grants", "One request may carry one grant's placeholder.", nil),
         state}

      [grant] ->
        authorize(state, grant, request, from)
    end
  end

  @impl true
  def handle_cast({:log, attrs}, state), do: {:noreply, log(state, attrs)}

  def handle_cast({:proxy, status}, state) do
    {:noreply, change(state, :proxy, fn _ -> status end)}
  end

  ## Timers, tasks and the build

  @impl true
  def handle_info(:poll, state) do
    Process.send_after(self(), :poll, @poll_every)

    if state.vm.busy != nil or Enum.any?(Map.values(state.tasks), &(&1 == :check)),
      do: {:noreply, state},
      else: {:noreply, check(state)}
  end

  def handle_info({:expire_grant, id, expires_at}, state) do
    case Enum.find(state.grants, &(&1.id == id)) do
      %Grant{state: :on, expires_at: ^expires_at} = grant ->
        {:noreply,
         state
         |> settle_waiting(id, :grant_off)
         |> replace_grant(%{grant | state: :off, expires_at: nil, allowances: []})
         |> log(%{
           outcome: :grant,
           summary: "#{grant.name} turned off: its time ran out",
           grant_id: id
         })
         |> write_inbox()
         |> changed()}

      _changed ->
        {:noreply, state}
    end
  end

  def handle_info({:expire_allowance, id, allowance_id}, state) do
    case Enum.find(state.grants, &(&1.id == id)) do
      nil ->
        {:noreply, state}

      grant ->
        allowances = Enum.reject(grant.allowances, &(&1.id == allowance_id))
        {:noreply, state |> replace_grant(%{grant | allowances: allowances}) |> changed()}
    end
  end

  def handle_info({:give_up, approval_id}, state) do
    case Enum.find(state.approvals, &(&1.id == approval_id and &1.status == :waiting)) do
      nil ->
        {:noreply, state}

      approval ->
        minutes =
          approval.deadline |> DateTime.diff(approval.requested_at) |> div(60) |> max(1)

        {:noreply,
         state
         |> settle(approval, :timed_out, nil)
         |> answer_waiters(approval, {:deny, :timed_out})
         |> log(event_for(approval, :timed_out, "gave up after #{minutes} min"))}
    end
  end

  # An agent waited as long as it said it would: it hears "still waiting",
  # and the ask stays for you.
  def handle_info({:stop_waiting, approval_id, ref}, state) do
    {mine, others} =
      state.waiters
      |> Map.get(approval_id, [])
      |> Enum.split_with(&match?({_from, {:await, ^ref}}, &1))

    Enum.each(mine, fn {from, _} -> GenServer.reply(from, :pending) end)

    waiters =
      if others == [],
        do: Map.delete(state.waiters, approval_id),
        else: Map.put(state.waiters, approval_id, others)

    {:noreply, %{state | waiters: waiters}}
  end

  def handle_info(:flush, state) do
    :ok = persist(state)
    {:noreply, %{state | flush: nil}}
  end

  def handle_info({port, {:data, {_eol, line}}}, %{build: port} = state) do
    {:noreply, build_line(state, line)}
  end

  def handle_info({port, {:exit_status, status}}, %{build: port} = state) do
    state = %{state | build: nil}

    state =
      if status == 0 do
        built(state, Image.read_build(build_dir(state), state.image.building))
      else
        state
        |> change(
          :image,
          &%{
            &1.image
            | building?: false,
              building: nil,
              error: "The build failed (exit #{status}). See the log."
          }
        )
        |> log(%{outcome: :vm, summary: "Image build failed"})
      end

    {:noreply, state}
  end

  def handle_info({ref, result}, state) when is_map_key(state.tasks, ref) do
    Process.demonitor(ref, [:flush])
    {purpose, tasks} = Map.pop(state.tasks, ref)
    {:noreply, finished(%{state | tasks: tasks}, purpose, result)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state)
      when is_map_key(state.tasks, ref) do
    {purpose, tasks} = Map.pop(state.tasks, ref)

    {:noreply,
     finished(%{state | tasks: tasks}, purpose, {:error, "crashed: #{inspect(reason)}"})}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  # Crash reports print the state; the vault key, real values, minted
  # tokens and private keys must never reach a log.
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

      other ->
        other
    end)
  end

  @impl true
  def terminate(_reason, state) do
    persist(state)

    # Locking MDT or quitting it leaves no VM running without the proxy.
    if state.vm.exists? and state.vm.status in [:running, :starting] do
      Msb.run(["stop", state.vm.name], 20)
    end

    :ok
  end

  ## Authorizing a request

  defp authorize(state, grant, request, from) do
    description = Describe.request(request)
    title = description.title

    cond do
      not host_allowed?(request.host, grant.hosts) ->
        state =
          log(state, %{
            outcome: :violation,
            summary: "#{grant.name} placeholder sent to #{request.host} · blocked",
            host: request.host,
            port: 443,
            grant_id: grant.id,
            method: request.method,
            path: request.path
          })

        {:reply,
         deny(
           403,
           "mdt_placeholder_blocked",
           "#{grant.name} may not go to #{request.host}.",
           grant
         ), state}

      not Grant.on?(grant) ->
        state =
          log(state, request_event(request, grant, :refused, "#{title} · #{grant.name} is off"))

        {:reply,
         deny(
           403,
           "mdt_grant_off",
           "#{grant.name} is off. Ask for it with: mdt request #{grant.id} --reason \"...\"",
           grant
         ), state}

      allowance = Enum.find(grant.allowances, &Allowance.covers?(&1, description.pattern)) ->
        why =
          if allowance.pattern == :all,
            do: "every use allowed",
            else: "allowed like an earlier one"

        state = log(state, request_event(request, grant, :swapped, "#{title} · #{why}"))
        {:noreply, forward(state, grant, request, from)}

      true ->
        approval = %Approval{
          id: "approval-" <> unique(),
          grant_id: grant.id,
          kind: :request,
          title: title,
          method: request.method,
          host: request.host,
          path: request.path,
          pattern: description.pattern,
          request: request,
          requested_at: now(),
          deadline: DateTime.add(now(), state.settings.hold_seconds, :second),
          facts: description.facts,
          claims: description.claims
        }

        {:noreply, hold(state, approval, {from, {:request, request}})}
    end
  end

  # Joins a waiting approval with the same pattern, so a client's retries are
  # one decision, or starts a new one.
  defp hold(state, approval, waiter) do
    case Enum.find(state.approvals, fn other ->
           other.status == :waiting and other.grant_id == approval.grant_id and
             other.pattern == approval.pattern
         end) do
      %Approval{} = waiting ->
        state
        |> replace_approval(%{waiting | retries: waiting.retries + 1})
        |> add_waiter(waiting.id, waiter)

      nil ->
        Process.send_after(
          self(),
          {:give_up, approval.id},
          max(DateTime.diff(approval.deadline, now(), :millisecond), 0)
        )

        state
        |> add_waiter(approval.id, waiter)
        |> change(:approvals, &[approval | &1.approvals])
    end
  end

  defp add_waiter(state, approval_id, waiter),
    do:
      Map.update!(
        state,
        :waiters,
        &Map.update(&1, approval_id, [waiter], fn list -> list ++ [waiter] end)
      )

  # Fetches the value, then answers the proxy with the headers it carries.
  defp forward(state, grant, request, from) do
    with_value(state, grant, fn state, result ->
      case result do
        {:ok, value} ->
          GenServer.reply(
            from,
            {:forward, swap(request.headers, grant.placeholder, value),
             [{value, grant.placeholder}]}
          )

          used(state, grant.id)

        {:error, :no_value} ->
          GenServer.reply(
            from,
            deny(503, "mdt_no_value", "#{grant.name} has no value yet.", grant)
          )

          log(state, request_event(request, grant, :refused, "#{grant.name} has no value set"))

        {:error, message} ->
          GenServer.reply(
            from,
            deny(502, "mdt_mint_failed", "Could not mint a token for #{grant.name}.", grant)
          )

          log(state, request_event(request, grant, :refused, "Minting failed: #{message}"))
      end
    end)
  end

  defp with_value(state, %Grant{source: :stored} = grant, k) do
    case state.values do
      %{} = values when is_map_key(values, grant.id) -> k.(state, {:ok, values[grant.id]})
      _ -> k.(state, {:error, :no_value})
    end
  end

  defp with_value(state, %Grant{source: {:minted, command}} = grant, k) do
    fresh_since = System.monotonic_time(:millisecond) - @mint_fresh_ms

    case {state.minted[grant.id], state.minting[grant.id]} do
      {{value, at}, _} when at > fresh_since ->
        k.(state, {:ok, value})

      {_, [_ | _] = waiting} ->
        %{state | minting: Map.put(state.minting, grant.id, waiting ++ [k])}

      _none ->
        state
        |> task({:mint, grant.id}, fn -> mint(command) end)
        |> Map.update!(:minting, &Map.put(&1, grant.id, [k]))
    end
  end

  defp mint(command) do
    case System.cmd("timeout", ["30", "bash", "-lc", command], stderr_to_stdout: false) do
      {output, 0} ->
        case String.trim(output) do
          "" -> {:error, "the command printed nothing"}
          token -> {:ok, token}
        end

      {_output, status} ->
        {:error, "the command exited with #{status}"}
    end
  end

  # Placeholders are long and random, so a plain substring is unambiguous.
  defp carries?(headers, placeholder) when is_binary(placeholder) do
    Enum.any?(headers, fn {_name, value} ->
      String.contains?(value, placeholder) or String.contains?(basic(value) || "", placeholder)
    end)
  end

  defp carries?(_headers, nil), do: false

  defp swap(headers, placeholder, value) do
    Enum.map(headers, fn {name, header} ->
      case basic(header) do
        decoded when is_binary(decoded) ->
          if String.contains?(decoded, placeholder),
            do: {name, "Basic " <> Base.encode64(String.replace(decoded, placeholder, value))},
            else: {name, String.replace(header, placeholder, value)}

        nil ->
          {name, String.replace(header, placeholder, value)}
      end
    end)
  end

  defp basic(value) do
    with ["Basic", encoded] <- String.split(value, " ", parts: 2),
         {:ok, decoded} <- Base.decode64(String.trim(encoded)) do
      decoded
    else
      _ -> nil
    end
  end

  defp host_allowed?(host, hosts) do
    host = String.downcase(host || "")

    Enum.any?(hosts, fn
      "*." <> suffix -> host == suffix or String.ends_with?(host, "." <> suffix)
      exact -> host == String.downcase(exact)
    end)
  end

  defp deny(status, code, message, grant) do
    body =
      Jason.encode!(%{
        error: message,
        code: code,
        grant: grant && grant.name,
        by: "MDT agent sandbox"
      })

    {:deny, status, body}
  end

  defp request_event(request, grant, outcome, summary) do
    %{
      outcome: outcome,
      summary: summary,
      host: request.host,
      port: 443,
      grant_id: grant.id,
      method: request.method,
      path: request.path
    }
  end

  ## Decisions

  # Which decisions fit which approval: activations are answered by turning
  # a grant on (or setting one up), uses by letting them through.
  defp fits?(%Approval{kind: :activation, grant_id: nil}, decision, state) do
    case decision do
      {:set_up, grant_id} -> Enum.any?(state.grants, &(&1.id == grant_id))
      :decline -> true
      _other -> false
    end
  end

  defp fits?(%Approval{kind: :activation}, decision, _state) do
    case decision do
      {:turn_on, minutes, uses} -> uses in [:ask, :all] and duration?(minutes, :until_off)
      :decline -> true
      _other -> false
    end
  end

  defp fits?(%Approval{}, decision, _state) do
    case decision do
      :allow_once -> true
      {:allow, scope, duration} -> scope in [:similar, :all] and duration?(duration, :grant)
      :deny -> true
      :deny_and_turn_off -> true
      _other -> false
    end
  end

  defp duration?(minutes, _open) when is_integer(minutes) and minutes > 0, do: true
  defp duration?(open, open), do: true
  defp duration?(_other, _open), do: false

  defp decide(state, approval, {:turn_on, minutes, uses}) do
    grant = Enum.find(state.grants, &(&1.id == approval.grant_id))

    state
    |> settle(approval, :allowed, {:turn_on, minutes, uses})
    |> turn_on(grant, minutes, uses, " · asked by #{approval.agent}")
    |> answer_waiters(approval, :allow)
  end

  defp decide(state, approval, {:set_up, grant_id}) do
    grant = Enum.find(state.grants, &(&1.id == grant_id))
    approval = %{approval | grant_id: grant_id}
    minutes = approval.minutes

    state
    |> replace_approval(approval)
    |> settle(approval, :allowed, {:set_up, grant_id})
    |> turn_on(grant, minutes, :ask, " · asked by #{approval.agent}")
    |> answer_waiters(approval, :allow)
  end

  defp decide(state, approval, :decline) do
    state
    |> settle(approval, :denied, :decline)
    |> answer_waiters(approval, {:deny, :by_you})
    |> log(event_for(approval, :denied, "you declined"))
  end

  defp decide(state, approval, :allow_once) do
    state
    |> settle(approval, :allowed, :allow_once)
    |> answer_waiters(approval, :allow)
    |> log(event_for(approval, :allowed, "you allowed once"))
  end

  defp decide(state, approval, {:allow, scope, duration}) do
    case Enum.find(state.grants, &(&1.id == approval.grant_id)) do
      nil ->
        decide(state, approval, :allow_once)

      grant ->
        pattern = if scope == :all, do: :all, else: approval.pattern

        state
        |> allow(grant, pattern, duration)
        |> log(%{
          outcome: :grant,
          summary:
            if(scope == :all,
              do: "#{grant.name}: every use allowed #{duration_words(duration)}",
              else:
                "#{grant.name}: uses like “#{approval.title}” allowed #{duration_words(duration)}"
            ),
          grant_id: grant.id
        })
    end
  end

  defp decide(state, approval, :deny) do
    state
    |> settle(approval, :denied, :deny)
    |> answer_waiters(approval, {:deny, :by_you})
    |> log(event_for(approval, :denied, "you denied"))
  end

  defp decide(state, approval, :deny_and_turn_off) do
    state =
      state
      |> settle(approval, :denied, :deny_and_turn_off)
      |> answer_waiters(approval, {:deny, :by_you})
      |> log(event_for(approval, :denied, "you denied"))

    case Enum.find(state.grants, &(&1.id == approval.grant_id)) do
      nil ->
        state

      grant ->
        state
        |> settle_waiting(grant.id, :grant_off)
        |> replace_grant(%{grant | state: :off, expires_at: nil, allowances: []})
        |> log(%{
          outcome: :grant,
          summary: "#{grant.name} turned off from an approval",
          grant_id: grant.id
        })
        |> write_inbox()
        |> changed()
    end
  end

  # Adds an allowance to an on grant, and lets through every use waiting on
  # it that the allowance covers.
  defp allow(state, grant, pattern, duration) do
    allowance = %Allowance{
      id: "allowance-" <> unique(),
      pattern: pattern,
      until: if(duration == :grant, do: nil, else: DateTime.add(now(), duration * 60, :second))
    }

    if allowance.until do
      Process.send_after(self(), {:expire_allowance, grant.id, allowance.id}, duration * 60_000)
    end

    state =
      state.approvals
      |> Enum.filter(fn other ->
        other.status == :waiting and other.grant_id == grant.id and Approval.use?(other) and
          Allowance.covers?(allowance, other.pattern)
      end)
      |> Enum.reduce(state, fn other, acc ->
        how = if pattern == :all, do: "every use", else: "similar"

        acc
        |> settle(
          other,
          :allowed,
          {:allow, if(pattern == :all, do: :all, else: :similar), duration}
        )
        |> answer_waiters(other, :allow)
        |> log(event_for(other, :allowed, "you allowed #{how} #{duration_words(duration)}"))
      end)

    grant = Enum.find(state.grants, &(&1.id == grant.id))

    state
    |> replace_grant(%{grant | allowances: grant.allowances ++ [allowance]})
    |> changed()
  end

  # Turns a grant on for `minutes` (or `:until_off`); `:all` also lets every
  # use through for as long as it stays on.
  defp turn_on(state, nil, _minutes, _uses, _why), do: state

  defp turn_on(state, grant, minutes, uses, why) do
    expires_at =
      if minutes == :until_off, do: nil, else: DateTime.add(now(), minutes * 60, :second)

    grant = %{grant | state: :on, expires_at: expires_at}
    schedule_expiry(grant)

    state =
      state
      |> replace_grant(grant)
      |> log(%{
        outcome: :grant,
        summary:
          "#{grant.name} turned on #{duration_words(minutes)}" <>
            if(uses == :all, do: ", every use allowed", else: "") <> why,
        grant_id: grant.id
      })
      |> write_inbox()
      |> changed()

    if uses == :all, do: allow(state, grant, :all, :grant), else: state
  end

  # Turning a grant on yourself answers the agents waiting for it.
  defp settle_activations(state, grant_id, minutes, uses) do
    state.approvals
    |> Enum.filter(
      &(&1.status == :waiting and &1.kind == :activation and &1.grant_id == grant_id)
    )
    |> Enum.reduce(state, fn approval, acc ->
      acc
      |> settle(approval, :allowed, {:turn_on, minutes, uses})
      |> answer_waiters(approval, :allow)
    end)
  end

  # Answers everyone held on `approval`: the proxy's connections and
  # requests, and agents waiting through the channel.
  defp answer_waiters(state, approval, outcome) do
    {waiters, all} = Map.pop(state.waiters, approval.id, [])
    state = %{state | waiters: all}
    grant = Enum.find(state.grants, &(&1.id == approval.grant_id))
    settled = Enum.find(state.approvals, &(&1.id == approval.id)) || approval

    Enum.reduce(waiters, state, fn
      {from, {:await, _ref}}, acc ->
        GenServer.reply(from, {:ok, settled, grant})
        acc

      {from, :connection}, acc ->
        GenServer.reply(from, if(outcome == :allow, do: :ok, else: {:deny, "Not allowed"}))
        if outcome == :allow, do: used(acc, approval.grant_id), else: acc

      {from, {:request, request}}, acc ->
        case {outcome, grant} do
          {:allow, %Grant{}} ->
            forward(acc, grant, request, from)

          {{:deny, :timed_out}, _} ->
            GenServer.reply(
              from,
              deny(403, "mdt_approval_timeout", "Nobody decided in time.", grant)
            )

            acc

          {{:deny, :grant_off}, _} ->
            GenServer.reply(
              from,
              deny(403, "mdt_grant_off", "The grant turned off while this waited.", grant)
            )

            acc

          _denied ->
            GenServer.reply(
              from,
              deny(403, "mdt_denied_by_user", "The user denied this request.", grant)
            )

            acc
        end
    end)
  end

  ## Activations

  # What an agent asked for, checked: a grant that exists (by id, or by name
  # in any case), or a `need` no grant meets yet.
  defp activation(state, ask) do
    reason = ask |> Map.get(:reason, "") |> to_string() |> String.trim() |> String.slice(0, 1_000)
    agent = ask |> Map.get(:agent) |> to_string() |> String.trim() |> String.slice(0, 60)
    agent = if agent == "", do: "An agent", else: agent
    minutes = Map.get(ask, :minutes) || 60
    wanted = ask |> Map.get(:grant) |> to_string() |> String.trim()
    need = ask |> Map.get(:need) |> to_string() |> String.trim() |> String.slice(0, 400)

    grant =
      Enum.find(state.grants, &(&1.id == wanted)) ||
        Enum.find(state.grants, &(String.downcase(&1.name) == String.downcase(wanted)))

    waiting = Enum.filter(state.approvals, &(&1.status == :waiting and &1.kind == :activation))
    pattern = if grant, do: "activate #{grant.id}", else: "need #{need}"

    cond do
      reason == "" ->
        {:error, :no_reason}

      not (is_integer(minutes) and minutes in 1..1440) ->
        {:error, :bad_minutes}

      wanted == "" and need == "" ->
        {:error, :nothing_asked}

      wanted != "" and is_nil(grant) ->
        {:error, :unknown_grant}

      grant && Grant.on?(grant) ->
        {:already_on, grant}

      length(waiting) >= @max_waiting_activations and
          not Enum.any?(waiting, &(&1.pattern == pattern)) ->
        {:error, :too_many}

      true ->
        {:ok,
         %Approval{
           id: "ask-" <> unique(),
           kind: :activation,
           grant_id: grant && grant.id,
           title:
             if(grant,
               do: "Turn on #{grant.name}",
               else: "Access you haven't set up"
             ),
           agent: agent,
           minutes: minutes,
           need: if(grant, do: nil, else: need),
           reason: reason,
           pattern: pattern,
           requested_at: now(),
           deadline: DateTime.add(now(), @activation_hold_seconds, :second),
           claims: [{"Reason", reason}]
         }}
    end
  end

  # One waiting ask per grant (and per described need): asking again joins it.
  defp hold_activation(state, approval) do
    case Enum.find(state.approvals, fn other ->
           other.status == :waiting and other.kind == :activation and
             other.pattern == approval.pattern
         end) do
      %Approval{} = waiting ->
        joined = %{waiting | retries: waiting.retries + 1}
        {replace_approval(state, joined), joined}

      nil ->
        Process.send_after(
          self(),
          {:give_up, approval.id},
          @activation_hold_seconds * 1_000
        )

        {change(state, :approvals, &[approval | &1.approvals]), approval}
    end
  end

  defp grant_of(state, %Approval{grant_id: id}), do: Enum.find(state.grants, &(&1.id == id))

  ## The VM

  defp vm_task(state, action, busy) do
    state = state |> write_inbox() |> change(:vm, &%{&1.vm | busy: busy, error: nil})
    name = state.vm.name
    folders = state.folders

    work =
      case action do
        :start ->
          fn ->
            with :ok <- prepare(folders) do
              Msb.run(["start", name], 120)
            end
          end

        :stop ->
          fn -> Msb.run(["stop", name], 60) end
      end

    task(state, {:vm, action}, work)
  end

  @create_defaults %{home: :keep, cache: :keep, seed_memory: false}

  # Creating (or recreating) the VM: stop it, snapshot Home, apply what you
  # chose for Home, Cache and the VM's memory, prepare the folders, then
  # `msb create --replace`. All of it in a task, with the VM stopped.
  defp create(state, options, busy) do
    options = Map.merge(@create_defaults, options || %{})

    with :ok <- check_options(state, options) do
      state = state |> write_inbox() |> change(:vm, &%{&1.vm | busy: busy, error: nil})
      spec = vm_spec(state)
      args = Msb.create_args(Map.put(spec, :env, Inbox.env(state.grants)))

      job = %{
        name: state.vm.name,
        existed?: state.vm.exists?,
        folders: state.folders,
        snapshots: state.snapshots,
        snapshot_tag: tag_of(state.created_ref),
        ref: state.image.tag,
        spec: :erlang.phash2(spec),
        args: args,
        options: options
      }

      {:reply, :ok, task(state, {:vm, :create}, fn -> run_create(job) end)}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp check_options(state, options) do
    cond do
      options.home not in [:keep, :empty] and
          not match?({:snapshot, id} when is_binary(id), options.home) ->
        {:error, :bad_options}

      match?({:snapshot, _}, options.home) and
          not Enum.any?(state.snapshots, &({:snapshot, &1.id} == options.home)) ->
        {:error, :no_snapshot}

      options.cache not in [:keep, :clear] ->
        {:error, :bad_options}

      options.seed_memory == true and not Memory.host_memory?() ->
        {:error, :no_memory}

      true ->
        :ok
    end
  end

  defp run_create(job) do
    if job.existed?, do: Msb.run(["stop", job.name], 60)
    Folders.ensure!(job.folders)

    # Home is copied before anything changes it, so emptying it or going back
    # to an older snapshot can be undone.
    {snapshots, taken} =
      if job.existed? and not Folders.empty?(job.folders.home) do
        snapshot = Folders.snapshot!(job.folders, job.snapshot_tag, now())
        {[snapshot | job.snapshots], snapshot}
      else
        {job.snapshots, nil}
      end

    outcome =
      try do
        case job.options.home do
          :keep -> :ok
          :empty -> Folders.empty!(job.folders.home)
          {:snapshot, id} -> Folders.restore!(job.folders, Enum.find(snapshots, &(&1.id == id)))
        end

        if job.options.cache == :clear, do: Folders.empty!(job.folders.cache)
        seed = if job.options.seed_memory, do: Memory.seed!(job.folders.optmem)

        with :ok <- prepare(job.folders) do
          {Msb.run(job.args, 300), seed}
        else
          error -> {error, seed}
        end
      rescue
        error -> {{:error, Exception.message(error)}, nil}
      end

    {kept, removed} = Folders.keep(snapshots)
    Enum.each(removed, &Folders.delete!(job.folders, &1))
    {result, seed} = outcome

    %{
      result: result,
      spec: job.spec,
      ref: job.ref,
      snapshots: kept,
      taken: taken,
      seed: seed,
      options: job.options
    }
  end

  # Before every start: the folders exist, the VM's memory has its tool, and
  # Home carries MDT's instructions for agents. The VM is stopped meanwhile.
  defp prepare(folders) do
    Folders.ensure!(folders)
    Memory.prepare!(folders.optmem)
    Instructions.write_home!(folders.home, Instructions.text())
    :ok
  rescue
    error -> {:error, "Preparing the VM's folders failed: " <> Exception.message(error)}
  end

  defp seed_task(state) do
    optmem = state.folders.optmem

    state
    |> change(:vm, &%{&1.vm | busy: "Copying your memory…", error: nil})
    |> task(:seed_memory, fn ->
      try do
        {:ok, Memory.seed!(optmem)}
      rescue
        error -> {:error, Exception.message(error)}
      end
    end)
  end

  defp vm_spec(state) do
    shares = for share <- state.settings.shares, do: {share.path, share.path, share.mode}

    %{
      name: state.vm.name,
      image: state.image.tag,
      shell: "/bin/bash",
      cpus: state.settings.cpus,
      memory_gib: state.settings.memory_gib,
      proxy_port: state.settings.proxy_port,
      vsock: Channel.socket_path(state.username),
      mounts:
        shares ++
          [
            {inbox_dir(state), "/mnt/mdt", :ro},
            {state.folders.home, "/root", :rw},
            {state.folders.optmem, "/root/.optmem", :rw},
            {state.folders.cache, "/cache", :rw}
          ]
    }
  end

  defp tag_of(nil), do: nil

  defp tag_of(ref) do
    case String.split(ref, ":", parts: 2) do
      [_name, tag] -> tag
      [ref] -> ref
    end
  end

  defp stale?(%{vm: %VM{exists?: false}}), do: false

  defp stale?(state),
    do: not is_nil(state.created_spec) and state.created_spec != :erlang.phash2(vm_spec(state))

  defp check(state) do
    name = state.vm.name
    tag = state.image.tag
    task(state, :check, fn -> %{status: Msb.status(name), image?: Msb.image?(tag)} end)
  end

  defp finished(state, :check, %{status: status, image?: image?}) do
    vm =
      case status do
        {:ok, status} -> %{state.vm | exists?: true, status: status}
        :missing -> %{state.vm | exists?: false, status: :stopped}
        {:error, message} -> %{state.vm | error: message}
      end

    vm =
      if vm.status == :running and is_nil(state.vm.started_at),
        do: %{vm | started_at: now()},
        else: vm

    vm = if vm.status != :running, do: %{vm | started_at: nil}, else: vm

    state
    |> change(:vm, fn _ -> vm end)
    |> change(:image, fn state ->
      if state.image.building?, do: state.image, else: %{state.image | loaded?: image?}
    end)
  end

  defp finished(state, :check, _crashed), do: state

  defp finished(state, {:vm, :create}, %{} = done) do
    state =
      state
      |> change(:snapshots, fn _ -> done.snapshots end)
      |> seeded(done.seed)
      |> changed()

    state =
      if done.taken,
        do:
          log(state, %{outcome: :vm, summary: "Home copied before recreating (#{done.taken.id})"}),
        else: state

    case done.result do
      {:ok, _output} ->
        state
        |> Map.merge(%{created_spec: done.spec, created_ref: done.ref})
        |> change(
          :vm,
          &%{&1.vm | busy: nil, exists?: true, status: :running, started_at: now(), error: nil}
        )
        |> log(%{
          outcome: :vm,
          summary: "VM created from #{done.ref} and started#{create_words(done.options)}"
        })
        |> changed()

      error ->
        finished(state, {:vm, :create_failed}, error)
    end
  end

  defp finished(state, :seed_memory, result) do
    case result do
      {:ok, count} ->
        state
        |> change(:vm, &%{&1.vm | busy: nil})
        |> seeded(count)
        |> changed()

      {:error, message} ->
        state
        |> change(:vm, &%{&1.vm | busy: nil, error: "Copying your memory failed: " <> message})
        |> log(%{outcome: :vm, summary: "Copying your memory into the VM failed"})
    end
  end

  defp finished(state, {:vm, :start}, {:ok, _output}) do
    state
    |> change(:vm, &%{&1.vm | busy: nil, status: :running, started_at: now(), error: nil})
    |> log(%{outcome: :vm, summary: "VM started"})
  end

  defp finished(state, {:vm, :stop}, {:ok, _output}) do
    state
    |> change(:vm, &%{&1.vm | busy: nil, status: :stopped, started_at: nil, error: nil})
    |> log(%{outcome: :vm, summary: "VM stopped"})
  end

  defp finished(state, {:vm, action}, result) do
    message =
      case result do
        {:error, message} -> message
        other -> inspect(other)
      end

    state
    |> change(:vm, &%{&1.vm | busy: nil, error: message})
    |> log(%{outcome: :vm, summary: "msb #{action} failed: #{String.slice(message, 0, 200)}"})
    |> check()
  end

  defp finished(state, {:mint, grant_id}, result) do
    {continuations, minting} = Map.pop(state.minting, grant_id, [])

    state = %{state | minting: minting}

    state =
      case result do
        {:ok, value} ->
          %{
            state
            | minted:
                Map.put(state.minted, grant_id, {value, System.monotonic_time(:millisecond)})
          }

        _ ->
          state
      end

    Enum.reduce(continuations, state, fn k, acc -> k.(acc, result) end)
  end

  defp finished(state, :env, _result), do: state
  defp finished(state, :delete_builds, _result), do: state

  defp seeded(state, nil), do: state

  defp seeded(state, count) do
    state
    |> change(:memory, fn _ -> %{seed_count: count, seeded_at: now(), reviewed: count} end)
    |> log(%{outcome: :vm, summary: "The VM's memory now starts from yours (#{count} memories)"})
  end

  defp create_words(options) do
    words =
      Enum.reject(
        [
          options.home == :empty && "Home emptied",
          match?({:snapshot, _}, options.home) && "Home from a snapshot",
          options.cache == :clear && "Cache cleared",
          options.seed_memory && "memory copied from yours"
        ],
        &(&1 == false)
      )

    if words == [], do: "", else: " · " <> Enum.join(words, ", ")
  end

  # Placeholders reach processes started later in a running VM; shells also
  # read them from /mnt/mdt/env.sh.
  defp sync_env(%{vm: %VM{exists?: true}} = state, added, removed) do
    set = for {key, value} <- Inbox.env(added), do: ["--env", "#{key}=#{value}"]
    unset = for {key, _value} <- Inbox.env(removed), do: ["--env-rm", key]
    args = List.flatten(set ++ unset)

    if args == [],
      do: state,
      else: task(state, :env, fn -> Msb.run(["modify", state.vm.name | args], 30) end)
  end

  defp sync_env(state, _added, _removed), do: state

  ## The image

  defp build_dir(state), do: Path.join(state.dir, "build")

  defp start_build(state) do
    dir = build_dir(state)
    name = state.settings.image_name
    today = NaiveDateTime.local_now() |> NaiveDateTime.to_date()
    tag = Image.next_tag(name, today, state.builds)
    ref = "#{name}:#{tag}"
    Image.write_context(dir, state.settings.containerfile)

    building = %{
      name: name,
      tag: tag,
      containerfile: state.settings.containerfile,
      built_at: now()
    }

    port =
      Port.open({:spawn_executable, System.find_executable("bash")}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:line, 2_000},
        args: ["-c", Image.build_script(dir, ref)],
        env: Enum.map(Msb.env(), fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)
      ])

    %{state | build: port}
    |> change(:image, &%{&1.image | building?: true, building: building, error: nil, log: []})
    |> log(%{outcome: :vm, summary: "Building image #{ref}"})
  end

  # A finished build becomes current. Builds beyond the newest three go,
  # except the one the VM was created from.
  defp built(state, %Build{} = build) do
    builds = [build | Enum.reject(state.builds, &(&1.ref == build.ref))]
    {kept, removed} = Image.keep(builds, Enum.reject([state.created_ref], &is_nil/1))

    state =
      state
      |> change(:builds, fn _ -> kept end)
      |> change(
        :image,
        &%{&1.image | tag: build.ref, loaded?: true, building?: false, building: nil, error: nil}
      )
      |> log(%{outcome: :vm, summary: "Image #{build.ref} built"})
      |> changed()

    if removed == [] do
      state
    else
      refs = Enum.map(removed, & &1.ref)

      state
      |> log(%{outcome: :vm, summary: "Older images deleted: #{Enum.join(refs, ", ")}"})
      |> task(:delete_builds, fn -> Enum.each(refs, &Image.delete/1) end)
    end
  end

  defp build_line(state, line) do
    image = %{state.image | log: Enum.take([line | state.image.log], @build_log_limit)}
    broadcast(state, {:sandbox_build_line, line})
    %{state | image: image}
  end

  defp ca_pem(state), do: CertificateAuthority.pem(state.ca.cert)

  ## Grants

  defp with_grant(state, id, fun) do
    case Enum.find(state.grants, &(&1.id == id)) do
      nil ->
        {:reply, {:error, :not_found}, state}

      grant ->
        {updated, summary} = fun.(grant)

        state =
          if grant.state == :on and updated.state == :off,
            do: settle_waiting(state, id, :grant_off),
            else: state

        state = replace_grant(state, updated)

        state =
          if summary,
            do: log(state, %{outcome: :grant, summary: summary, grant_id: id}),
            else: state

        {:reply, {:ok, updated}, state |> write_inbox() |> changed()}
    end
  end

  defp build_grant(attrs, existing) do
    kind = Enum.find(Grant.kinds(), &(Atom.to_string(&1) == attrs["kind"]))

    preset =
      case Presets.find(attrs["preset"] || "") do
        {:ok, %{id: id}} when id not in [:token, :network, :file] -> id
        _none -> nil
      end

    if is_nil(kind) do
      {:error, %{kind: "Pick what kind of access this is."}}
    else
      name = String.trim(attrs["name"] || "")
      purpose = String.trim(attrs["purpose"] || "")
      minted? = kind == :token and attrs["source"] == "minted"
      {destinations, destination_error} = destinations(attrs["destinations"], kind)

      grant = %Grant{
        id: grant_id(name, existing),
        name: name,
        kind: kind,
        preset: preset,
        purpose: purpose,
        placeholder: if(kind == :token, do: placeholder(attrs["prefix"])),
        env: if(kind == :token, do: list(attrs["env"]), else: []),
        file_env: if(kind == :token, do: list(attrs["file_env"]), else: []),
        git: kind == :token and attrs["git"] in ["true", "on"],
        hosts:
          if(kind == :token, do: Enum.map(list(attrs["hosts"]), &String.downcase/1), else: []),
        destinations: destinations,
        path: if(kind == :file, do: "/mnt/mdt/files/" <> String.trim(attrs["path"] || "")),
        source: if(minted?, do: {:minted, String.trim(attrs["mint"] || "")}, else: :stored)
      }

      case grant_errors(grant, attrs, destination_error) do
        errors when errors == %{} ->
          {:ok, grant,
           if(minted? or kind == :network, do: nil, else: blank_to_nil(attrs["value"]))}

        errors ->
          {:error, errors}
      end
    end
  end

  @variable ~r/^[A-Za-z_][A-Za-z0-9_]*$/
  @host ~r/^(\*\.)?[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$/
  @prefix ~r/^[A-Za-z0-9_.\-]{0,24}$/

  defp grant_errors(%Grant{} = grant, attrs, destination_error) do
    token? = grant.kind == :token
    variables = grant.env ++ grant.file_env

    [
      {:name, grant.name == "", "Give it a name you'll recognise on an approval."},
      {:purpose, grant.purpose == "",
       "Say what it's for. Agents in the VM read this to find the grant they need."},
      {:hosts, token? and grant.hosts == [], "List at least one host the value may go to."},
      {:hosts, token? and not Enum.all?(grant.hosts, &Regex.match?(@host, &1)),
       "Hosts are names like api.example.com, or *.example.com for its subdomains."},
      {:env, token? and not Enum.all?(variables, &Regex.match?(@variable, &1)),
       "Variable names are letters, digits and underscores, not starting with a digit."},
      {:prefix, token? and not Regex.match?(@prefix, String.trim(attrs["prefix"] || "")),
       "Up to 24 letters, digits, dots, dashes or underscores."},
      {:destinations, grant.kind == :network and destination_error != nil, destination_error},
      {:path, grant.kind == :file and not valid_file_name?(attrs["path"]),
       "Name the file, such as kubeconfig. It appears under /mnt/mdt/files/."},
      {:mint, match?({:minted, ""}, grant.source),
       "Enter the command that prints a short-lived token."},
      {:value,
       grant.kind in [:token, :file] and grant.source == :stored and
         blank_to_nil(attrs["value"]) == nil,
       "Paste the value. It is kept in your vault, never in the VM."}
    ]
    |> Enum.filter(fn {_field, failed?, _message} -> failed? end)
    |> Enum.reverse()
    |> Map.new(fn {field, _failed?, message} -> {field, message} end)
  end

  defp destinations(text, kind) do
    entries = list(text)

    cond do
      kind != :network ->
        {[], nil}

      entries == [] ->
        {[], "List at least one host, address or range."}

      true ->
        case Destinations.parse_all(entries) do
          {:ok, _specs} -> {entries, nil}
          {:error, message} -> {entries, message}
        end
    end
  end

  defp specs(%Grant{destinations: destinations}) do
    case Destinations.parse_all(destinations) do
      {:ok, specs} -> specs
      {:error, _} -> []
    end
  end

  defp valid_file_name?(name) do
    name = String.trim(name || "")
    name != "" and Path.basename(name) == name and name not in [".", ".."]
  end

  # Placeholders look like the real thing where a client checks the format
  # (`ghp_` for GitHub), and are long and random, so finding one in a header
  # is unambiguous.
  defp placeholder(prefix) do
    prefix = String.trim(prefix || "")
    prefix = if prefix == "", do: "mdt_", else: prefix
    alphabet = ~c"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
    bytes = :crypto.strong_rand_bytes(40)
    prefix <> for(<<byte <- bytes>>, into: "", do: <<Enum.at(alphabet, rem(byte, 62))>>)
  end

  defp list(nil), do: []

  defp list(value) do
    value
    |> String.split([",", "\n"])
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) do
    case String.trim(value) do
      "" -> nil
      _ -> value
    end
  end

  defp grant_id(name, existing) do
    base =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")
      |> case do
        "" -> "grant"
        slug -> slug
      end

    if Enum.any?(existing, &(&1.id == base)), do: base <> "-" <> unique(), else: base
  end

  defp cast_settings(settings, attrs) do
    fields = [
      {:cpus, attrs["cpus"], &cast_int(&1, 1, 64)},
      {:memory_gib, attrs["memory_gib"], &cast_int(&1, 1, 512)},
      {:hold_seconds, attrs["hold_seconds"], &cast_int(&1, 30, 600)},
      {:proxy_port, attrs["proxy_port"], &cast_int(&1, 1024, 65_535)},
      {:containerfile, attrs["containerfile"], &cast_containerfile/1},
      {:image_name, attrs["image_name"], &cast_image_name/1}
    ]

    {changes, errors} =
      Enum.reduce(fields, {%{}, %{}}, fn
        {_field, nil, _cast}, acc ->
          acc

        {field, value, cast}, {changes, errors} ->
          case cast.(value) do
            {:ok, cast_value} -> {Map.put(changes, field, cast_value), errors}
            {:error, message} -> {changes, Map.put(errors, field, message)}
          end
      end)

    if errors == %{}, do: {:ok, struct!(settings, changes)}, else: {:error, errors}
  end

  defp cast_containerfile(value) do
    if Regex.match?(~r/^\s*FROM\s+\S+/mi, value),
      do: {:ok, String.replace(value, "\r\n", "\n")},
      else: {:error, "A Containerfile needs a FROM line."}
  end

  defp cast_image_name(value) do
    name = String.trim(value)

    if Image.valid_name?(name),
      do: {:ok, name},
      else:
        {:error, "Lowercase letters and digits, joined by single dots, underscores or dashes."}
  end

  defp cast_int(value, min, max) do
    case Integer.parse(String.trim(to_string(value))) do
      {int, ""} when int >= min and int <= max -> {:ok, int}
      _ -> {:error, "Enter a whole number from #{min} to #{max}."}
    end
  end

  ## State helpers

  defp replace_grant(state, grant) do
    change(
      state,
      :grants,
      &Enum.map(&1.grants, fn g -> if g.id == grant.id, do: grant, else: g end)
    )
  end

  defp replace_approval(state, approval) do
    change(
      state,
      :approvals,
      &Enum.map(&1.approvals, fn a -> if a.id == approval.id, do: approval, else: a end)
    )
  end

  defp used(state, grant_id) do
    case Enum.find(state.grants, &(&1.id == grant_id)) do
      nil ->
        state

      grant ->
        state |> replace_grant(%{grant | uses: grant.uses + 1, last_used_at: now()}) |> changed()
    end
  end

  defp settle(state, approval, status, decision) do
    approval = %{approval | status: status, decision: decision, decided_at: now()}

    change(state, :approvals, fn state ->
      {waiting, history} =
        state.approvals
        |> Enum.map(&if(&1.id == approval.id, do: approval, else: &1))
        |> Enum.split_with(&(&1.status == :waiting))

      waiting ++
        Enum.take(Enum.sort_by(history, & &1.decided_at, {:desc, DateTime}), @history_limit)
    end)
  end

  defp settle_waiting(state, grant_id, decision, kinds \\ [:request, :connection]) do
    state.approvals
    |> Enum.filter(&(&1.status == :waiting and &1.grant_id == grant_id and &1.kind in kinds))
    |> Enum.reduce(state, fn approval, acc ->
      acc
      |> settle(approval, :denied, decision)
      |> answer_waiters(approval, {:deny, :grant_off})
      |> log(event_for(approval, :refused, "its grant turned off"))
    end)
  end

  # Applies `fun` to the state under `area` and tells the pages.
  defp change(state, area, fun) do
    before = waiting_count(state)
    state = Map.put(state, area, fun.(state))
    broadcast(state, {:sandbox_changed, area})
    after_count = waiting_count(state)

    if before != after_count do
      Phoenix.PubSub.broadcast(
        MDTClient.PubSub,
        waiting_topic(state.username),
        {:sandbox_waiting, after_count}
      )
    end

    state
  end

  defp log(state, attrs) do
    event = struct!(Event, Map.merge(%{id: "event-" <> unique(), at: now()}, attrs))
    broadcast(state, {:sandbox_event, event})
    %{state | events: Enum.take([event | state.events], @event_limit)}
  end

  defp event_for(approval, outcome, how) do
    %{
      outcome: outcome,
      summary: "#{approval.title} · #{how}",
      host: approval.host,
      port: if(approval.kind == :connection, do: nil, else: 443),
      grant_id: approval.grant_id,
      method: approval.method,
      path: approval.path
    }
  end

  defp broadcast(state, message),
    do: Phoenix.PubSub.broadcast(MDTClient.PubSub, topic(state.username), message)

  defp waiting_count(state), do: Enum.count(state.approvals, &(&1.status == :waiting))

  defp task(state, purpose, fun) do
    %Task{ref: ref} = Task.Supervisor.async_nolink(@tasks, fun)
    %{state | tasks: Map.put(state.tasks, ref, purpose)}
  end

  defp inbox_dir(state), do: Path.join(state.dir, "inbox")

  defp write_inbox(state) do
    Inbox.write(inbox_dir(state), state.grants, state.values, ca_pem(state))
    state
  rescue
    error ->
      Logger.error("could not write the sandbox inbox: #{Exception.message(error)}",
        system: :sandbox
      )

      state
  end

  ## Timers

  defp schedule_expiry(%Grant{state: :on, expires_at: %DateTime{} = at, id: id}) do
    Process.send_after(
      self(),
      {:expire_grant, id, at},
      max(DateTime.diff(at, now(), :millisecond), 0)
    )
  end

  defp schedule_expiry(_grant), do: :ok

  ## Persistence

  defp changed(%{flush: nil} = state),
    do: %{state | flush: Process.send_after(self(), :flush, @flush_after)}

  defp changed(state), do: state

  defp persist(state) do
    partial = "#{state.path}.part"

    blob =
      Vault.seal(state.key, %{
        version: 1,
        grants: state.grants,
        values: state.values,
        settings: state.settings,
        ca: state.ca,
        created_spec: state.created_spec,
        created_ref: state.created_ref,
        builds: state.builds,
        current: state.image.tag,
        snapshots: state.snapshots,
        memory: state.memory
      })

    with :ok <- File.write(partial, blob),
         :ok <- File.rename(partial, state.path) do
      :ok
    else
      {:error, reason} ->
        Logger.error(
          "could not write the sandbox to #{state.path}: #{:file.format_error(reason)}",
          system: :sandbox
        )

        :ok
    end
  end

  defp restore(path, key, username) do
    case File.read(path) do
      {:ok, blob} ->
        case Vault.open(key, blob) do
          {:ok, %{version: 1} = saved} ->
            saved
            |> Map.update!(:grants, fn grants -> Enum.map(grants, &Grant.upgrade/1) end)
            |> Map.update(:builds, [], fn builds ->
              Enum.map(builds, &struct(Build, Map.from_struct(&1)))
            end)
            |> Map.update(:snapshots, [], fn snaps ->
              Enum.map(snaps, &struct(Snapshot, Map.from_struct(&1)))
            end)

          _unreadable ->
            corrupt = "#{path}.#{System.system_time(:second)}.corrupt"

            Logger.warning("sandbox at #{path} could not be decrypted; kept as #{corrupt}",
              user: username,
              system: :sandbox
            )

            File.rename(path, corrupt)
            %{}
        end

      {:error, _reason} ->
        %{}
    end
  end

  ## Small things

  defp duration_words(:until_off), do: "until turned off"
  defp duration_words(:grant), do: "while the grant is on"
  defp duration_words(60), do: "for 1 h"
  defp duration_words(minutes) when rem(minutes, 60) == 0, do: "for #{div(minutes, 60)} h"
  defp duration_words(minutes), do: "for #{minutes} min"

  defp unique, do: Integer.to_string(System.unique_integer([:positive]), 36) |> String.downcase()

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
