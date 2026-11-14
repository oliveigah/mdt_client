defmodule MDTClient.Sandbox.Server.Machine do
  @moduledoc """
  The VM and its image, in the sandbox server's state: creating, starting,
  stopping and recreating the VM in its bubble, its disks and their copies,
  seeding its memory, building the image, and noticing what changed while
  nobody looked.

  The slow work (`msb`, podman, copying disks) runs in tasks; what is here
  starts them and takes their results. Runs in the server's process
  (`MDTClient.Sandbox.Server.State`).
  """

  require Logger

  alias MDTClient.Sandbox.{Bubble, Build, Disks, Image, Inbox, Memory, Msb, VM}
  alias MDTClient.Sandbox.Server.{HostRuns, State}

  @build_log_limit 400

  @doc """
  The launcher Zed's SSH config names; a failure only matters there. A
  missing runtime is shown in the UI already.
  """
  def write_launcher(username) do
    case Msb.write_launcher(username) do
      :ok ->
        :ok

      {:error, :no_runtime} ->
        :ok

      {:error, reason} ->
        Logger.warning("could not write the msb launcher: #{inspect(reason)}", system: :sandbox)
    end
  end

  @doc """
  What is missing on this machine for a VM to run, in words for the user.
  """
  def needs do
    bubble =
      case Bubble.available() do
        :ok -> []
        {:error, message} -> [message]
      end

    relay = if Bubble.relay(), do: [], else: ["MDT's relay is missing from this build."]

    disks =
      case Disks.missing_tools() do
        [] -> []
        tools -> ["#{Enum.join(tools, ", ")} not found (package e2fsprogs)."]
      end

    bubble ++ relay ++ disks
  end

  @doc """
  Starts one of the VM's actions (start, stop, a copy of Home and the like) in a task, with `busy` as what the pages show meanwhile.
  """
  def vm_task(state, action, busy) do
    state = state |> State.write_inbox() |> State.change(:vm, &%{&1.vm | busy: busy, error: nil})

    # A VM made before MDT kept records gets one now, for its boot to write.
    state =
      if action == :start and is_nil(State.vm_record(state)),
        do: State.changed(Map.put(state, :vm_record, record(nil, state.created_ref))),
        else: state

    record = State.vm_record(state)
    name = state.vm.name
    username = state.username
    folders = state.folders
    sizes = disk_sizes(state.settings)
    bubble = bubble_spec(state)

    work =
      case action do
        :start ->
          fn ->
            with :ok <- prepare(folders, sizes),
                 {:ok, output} <- Bubble.start(bubble, ["start", name], 120) do
              boot(username, name, record)
              {:ok, output}
            end
          end

        :stop ->
          fn -> Bubble.stop(username) end
      end

    State.task(state, {:vm, action}, work)
  end

  @create_defaults %{home: :keep, cache: :keep, seed_memory: false}

  @doc """
  Creating (or recreating) the VM: stop it, snapshot Home, apply what you
  chose for Home, Cache and the VM's memory, prepare the folders, then
  `msb create --replace`. All of it in a task, with the VM stopped.
  """
  def create(state, options, busy) do
    options = Map.merge(@create_defaults, options || %{})

    with :ok <- check_options(state, options) do
      state =
        state |> State.write_inbox() |> State.change(:vm, &%{&1.vm | busy: busy, error: nil})

      spec = vm_spec(state)
      args = Msb.create_args(Map.put(spec, :env, Inbox.env(state.grants)))

      job = %{
        username: state.username,
        name: state.vm.name,
        existed?: state.vm.exists?,
        folders: state.folders,
        sizes: disk_sizes(state.settings),
        bubble: bubble_spec(state),
        snapshots: state.snapshots,
        snapshot_tag: tag_of(state.created_ref),
        ref: state.image.tag,
        record: record(State.now(), state.image.tag),
        spec: :erlang.phash2(spec),
        args: args,
        options: options
      }

      {:reply, :ok, State.task(state, {:vm, :create}, fn -> run_create(job) end)}
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
    # A clean stop first: the disks are copied and changed below, and a disk
    # the VM still writes must not be.
    {:ok, _} = Bubble.stop(job.username)
    Disks.ensure!(job.folders, job.sizes)

    # Home is copied before anything changes it, so emptying it or going back
    # to an older snapshot can be undone.
    {snapshots, taken} =
      if job.existed? do
        snapshot = Disks.snapshot!(job.folders, job.snapshot_tag, State.now())
        {[snapshot | job.snapshots], snapshot}
      else
        {job.snapshots, nil}
      end

    outcome =
      try do
        case job.options.home do
          :keep -> :ok
          :empty -> Disks.empty!(job.folders.home)
          {:snapshot, id} -> Disks.restore!(job.folders, Enum.find(snapshots, &(&1.id == id)))
        end

        if job.options.cache == :clear, do: Disks.empty!(job.folders.cache)
        seed = if job.options.seed_memory, do: Memory.seed!(job.folders.optmem)

        with :ok <- prepare(job.folders, job.sizes),
             {:ok, output} <- Bubble.start(job.bubble, job.args, 300) do
          boot(job.username, job.name, job.record)
          {{:ok, output}, seed}
        else
          error -> {error, seed}
        end
      rescue
        error -> {{:error, Exception.message(error)}, nil}
      end

    {kept, removed} = Disks.keep(snapshots)
    Enum.each(removed, &Disks.delete!(job.folders, &1))
    {result, seed} = outcome

    %{
      result: result,
      spec: job.spec,
      ref: job.ref,
      record: job.record,
      snapshots: kept,
      taken: taken,
      seed: seed,
      options: job.options
    }
  end

  # Before every start: the disks exist, at least as big as the settings
  # say, and so does the folder of the VM's memory. The VM is stopped
  # meanwhile. MDT writes nothing into any of them.
  defp prepare(folders, sizes) do
    Disks.ensure!(folders, sizes)
    File.mkdir_p!(folders.optmem)
    :ok
  rescue
    error -> {:error, "Preparing the VM's disks failed: " <> Exception.message(error)}
  end

  # After every boot, in the VM: it copies for itself what MDT has for it in
  # /mnt/mdt (the agents' instructions, the memo tool). A VM whose image
  # can't run the script still runs; the same text is at /mnt/mdt/AGENTS.md.
  # Which VM this is, for the boot script to write into it: a new id each
  # time MDT creates one.
  defp record(created_at, image) do
    %{
      id: :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower),
      created_at: created_at,
      image: image
    }
  end

  defp boot(username, name, record) do
    created = if record.created_at, do: DateTime.to_iso8601(record.created_at), else: ""
    args = [record.id, created, record.image || "", name]

    case Msb.run(username, ["exec", name, "--", "/mnt/mdt/bin/mdt-boot" | args], 60) do
      {:ok, _output} ->
        :ok

      {:error, message} ->
        Logger.warning("the VM's boot script failed: #{String.slice(message, 0, 300)}",
          system: :sandbox
        )
    end
  end

  defp disk_sizes(settings),
    do: %{home: settings.home_gib, cache: settings.cache_gib, work: settings.work_gib}

  defp bubble_spec(state) do
    %{
      username: state.username,
      name: state.vm.name,
      disks: state.folders.dir,
      inbox: State.inbox_dir(state),
      optmem: state.folders.optmem,
      shares: for(share <- state.settings.shares, do: {share.path, share.mode})
    }
  end

  @doc """
  Copies your memory into the VM's, in a task.
  """
  def seed_task(state) do
    optmem = state.folders.optmem

    state
    |> State.change(:vm, &%{&1.vm | busy: "Copying your memory…", error: nil})
    |> State.task(:seed_memory, fn ->
      try do
        {:ok, Memory.seed!(optmem)}
      rescue
        error -> {:error, Exception.message(error)}
      end
    end)
  end

  # What the VM is created with. Changing any of it means recreating the VM;
  # the disks' sizes are not here, since a disk grows at the next start.
  defp vm_spec(state) do
    %{
      name: state.vm.name,
      image: state.image.tag,
      shell: "/bin/bash",
      cpus: state.settings.cpus,
      memory_gib: state.settings.memory_gib,
      disk_gib: state.settings.disk_gib,
      write_budget_gib: state.settings.write_budget_gib,
      shares: for(share <- state.settings.shares, do: {share.path, share.mode})
    }
  end

  defp tag_of(nil), do: nil

  defp tag_of(ref) do
    case String.split(ref, ":", parts: 2) do
      [_name, tag] -> tag
      [ref] -> ref
    end
  end

  @doc """
  Whether the VM was created from other settings than the ones you have now.
  """
  def stale?(%{vm: %VM{exists?: false}}), do: false

  def stale?(state),
    do: not is_nil(state.created_spec) and state.created_spec != :erlang.phash2(vm_spec(state))

  @doc """
  Asks microsandbox and the relay how the VM and the image are, in a task.
  """
  def check(state) do
    username = state.username
    name = state.vm.name
    tag = state.image.tag

    State.task(state, :check, fn ->
      %{status: vm_status(username, name), image?: Msb.image?(username, tag)}
    end)
  end

  # Whether the VM runs is its relay's to say; whether it exists at all,
  # microsandbox's records.
  defp vm_status(username, name) do
    case Bubble.status(username) do
      :down ->
        case Msb.status(username, name) do
          :exists -> {:ok, :stopped}
          other -> other
        end

      up ->
        {:ok, up}
    end
  end

  @doc """
  Takes the result of a task that `vm_task/3`, `create/3`, `seed_task/1` or `check/1` started.
  """
  def finished(state, :check, %{status: status, image?: image?}) do
    vm =
      case status do
        {:ok, status} -> %{state.vm | exists?: true, status: status}
        :missing -> %{state.vm | exists?: false, status: :stopped}
        {:error, message} -> %{state.vm | error: message}
      end

    vm =
      if vm.status == :running and is_nil(state.vm.started_at),
        do: %{vm | started_at: State.now()},
        else: vm

    vm = if vm.status != :running, do: %{vm | started_at: nil}, else: vm

    state
    |> State.change(:vm, fn _ -> vm end)
    |> State.change(:image, fn state ->
      if state.image.building?, do: state.image, else: %{state.image | loaded?: image?}
    end)
  end

  def finished(state, :check, _crashed), do: state

  def finished(state, {:vm, :create}, %{} = done) do
    state =
      state
      |> State.change(:snapshots, fn _ -> done.snapshots end)
      |> seeded(done.seed)
      |> State.changed()

    state =
      if done.taken,
        do:
          State.log(state, %{
            outcome: :vm,
            summary: "Home copied before recreating (#{done.taken.id})"
          }),
        else: state

    case done.result do
      {:ok, _output} ->
        state
        |> Map.merge(%{created_spec: done.spec, created_ref: done.ref, vm_record: done.record})
        |> State.change(
          :vm,
          &%{
            &1.vm
            | busy: nil,
              exists?: true,
              status: :running,
              started_at: State.now(),
              error: nil
          }
        )
        |> State.log(%{
          outcome: :vm,
          summary: "VM created from #{done.ref} and started#{create_words(done.options)}"
        })
        |> State.changed()

      error ->
        finished(state, {:vm, :create_failed}, error)
    end
  end

  def finished(state, :seed_memory, result) do
    case result do
      {:ok, count} ->
        state
        |> State.change(:vm, &%{&1.vm | busy: nil})
        |> seeded(count)
        |> State.changed()

      {:error, message} ->
        state
        |> State.change(
          :vm,
          &%{&1.vm | busy: nil, error: "Copying your memory failed: " <> message}
        )
        |> State.log(%{outcome: :vm, summary: "Copying your memory into the VM failed"})
    end
  end

  def finished(state, {:vm, :start}, {:ok, _output}) do
    state
    |> State.change(
      :vm,
      &%{&1.vm | busy: nil, status: :running, started_at: State.now(), error: nil}
    )
    |> State.log(%{outcome: :vm, summary: "VM started"})
  end

  def finished(state, {:vm, :stop}, {:ok, _output}) do
    state
    |> State.change(:vm, &%{&1.vm | busy: nil, status: :stopped, started_at: nil, error: nil})
    |> State.log(%{outcome: :vm, summary: "VM stopped"})
  end

  def finished(state, {:vm, action}, result) do
    message =
      case result do
        {:error, message} -> message
        other -> inspect(other)
      end

    state
    |> State.change(:vm, &%{&1.vm | busy: nil, error: message})
    |> State.log(%{
      outcome: :vm,
      summary: "msb #{action} failed: #{String.slice(message, 0, 200)}"
    })
    |> check()
  end

  def finished(state, {:mint, grant_id}, result) do
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

  def finished(state, {:command, approval_id}, %{} = result),
    do: HostRuns.finished_command(state, approval_id, result)

  def finished(state, {:command, approval_id}, {:error, message}),
    do: HostRuns.finished_command(state, approval_id, %{error: message})

  def finished(state, :probe_host, tools) when is_list(tools) do
    state
    |> State.change(:host, &%{&1.host | tools: tools, probed_at: State.now(), probing?: false})
    |> State.write_host()
  end

  def finished(state, :probe_host, _crashed),
    do: State.change(state, :host, &%{&1.host | probing?: false})

  def finished(state, :env, _result), do: state

  # The mirror task tells the server what it did as it goes.
  def finished(state, :mirror, _result), do: state

  def finished(state, :delete_builds, _result), do: state

  defp seeded(state, nil), do: state

  defp seeded(state, count) do
    state
    |> State.change(:memory, fn _ ->
      %{seed_count: count, seeded_at: State.now(), reviewed: count}
    end)
    |> State.log(%{
      outcome: :vm,
      summary: "The VM's memory now starts from yours (#{count} memories)"
    })
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

  @doc """
  Placeholders reach processes started later in a running VM; shells also
  read them from /mnt/mdt/env.sh.
  """
  def sync_env(%{vm: %VM{exists?: true}} = state, added, removed) do
    set = for {key, value} <- Inbox.env(added), do: ["--env", "#{key}=#{value}"]
    unset = for {key, _value} <- Inbox.env(removed), do: ["--env-rm", key]
    args = List.flatten(set ++ unset)

    if args == [],
      do: state,
      else:
        State.task(state, :env, fn ->
          Msb.run(state.username, ["modify", state.vm.name | args], 30)
        end)
  end

  def sync_env(state, _added, _removed), do: state

  @doc """
  Where the image is built.
  """
  def build_dir(state), do: Path.join(state.dir, "build")

  @doc """
  Starts building the image, in a task that sends podman's output line by line.
  """
  def start_build(state) do
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
      built_at: State.now()
    }

    port =
      Port.open({:spawn_executable, System.find_executable("bash")}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:line, 2_000},
        args: ["-c", Image.build_script(dir, ref)],
        env:
          Enum.map(Msb.env(state.username), fn {k, v} ->
            {String.to_charlist(k), String.to_charlist(v)}
          end)
      ])

    %{state | build: port}
    |> State.change(
      :image,
      &%{&1.image | building?: true, building: building, error: nil, log: []}
    )
    |> State.log(%{outcome: :vm, summary: "Building image #{ref}"})
  end

  @doc """
  A finished build becomes current. Builds beyond the newest three go,
  except the one the VM was created from.
  """
  def built(state, %Build{} = build) do
    builds = [build | Enum.reject(state.builds, &(&1.ref == build.ref))]
    {kept, removed} = Image.keep(builds, Enum.reject([state.created_ref], &is_nil/1))

    state =
      state
      |> State.change(:builds, fn _ -> kept end)
      |> State.change(
        :image,
        &%{&1.image | tag: build.ref, loaded?: true, building?: false, building: nil, error: nil}
      )
      |> State.log(%{outcome: :vm, summary: "Image #{build.ref} built"})
      |> State.changed()

    if removed == [] do
      state
    else
      refs = Enum.map(removed, & &1.ref)
      username = state.username

      state
      |> State.log(%{outcome: :vm, summary: "Older images deleted: #{Enum.join(refs, ", ")}"})
      |> State.task(:delete_builds, fn -> Enum.each(refs, &Image.delete(username, &1)) end)
    end
  end

  @doc """
  Adds a line of the build's output to its log, which keeps the last 400.
  """
  def build_line(state, line) do
    image = %{state.image | log: Enum.take([line | state.image.log], @build_log_limit)}
    State.broadcast(state, {:sandbox_build_line, line})
    %{state | image: image}
  end
end
