defmodule MDTClient.Sandbox.Server.State do
  @moduledoc """
  The sandbox server's state, and the small things every part of the server
  does to it: change it and tell the pages, log an event, save it sealed,
  set a timer, start a task, write the VM's inbox.

  Nothing here decides anything. `MDTClient.Sandbox.Server` holds the state
  and takes the messages; `Approvals`, `Grants`, `Values`, `HostRuns` and
  `Machine`, next to this module, each do one job on it. All of it runs in
  the server's own process: these are its functions in files of their own,
  not processes.
  """

  require Logger

  alias MDTClient.Accounts
  alias MDTClient.Desktop.Notifications
  alias MDTClient.Vault

  alias MDTClient.Sandbox.{
    Allowance,
    Approval,
    Build,
    CertificateAuthority,
    DesktopNotice,
    Event,
    Grant,
    HostInfo,
    Inbox,
    Snapshot
  }

  @flush_after 250
  @event_limit 1_000
  @tasks MDTClient.Sandbox.TaskSupervisor

  @doc "The PubSub topic of everything that changes."
  def topic(username), do: "sandbox:" <> Accounts.id(username)

  @doc "The PubSub topic of the waiting count, which every page's title bar shows."
  def waiting_topic(username), do: "sandbox-waiting:" <> Accounts.id(username)

  @doc """
  A value taken out of the function it travelled in (`MDTClient.Sandbox.Server.call/3`); anything else as it is.
  """
  def opened(sealed) when is_function(sealed, 0), do: sealed.()

  def opened(plain), do: plain

  @doc """
  Tests run without touching microsandbox.
  """
  def external?,
    do:
      Keyword.get(Application.get_env(:mdt_client, MDTClient.Sandbox.Server, []), :external, true)

  @doc """
  The grant an approval is about, or nil.
  """
  def grant_of(state, %Approval{grant_id: id}), do: Enum.find(state.grants, &(&1.id == id))

  @doc """
  `value` when it is text, else the empty string: what the VM sends isn't trusted to be text.
  """
  def to_text(value) when is_binary(value), do: value

  def to_text(_other), do: ""

  @doc """
  What `mdt host` prints: this machine's description, your notes included.
  """
  def host_text(state),
    do:
      HostInfo.text(
        state.host.facts,
        state.host.tools,
        state.settings.shares,
        state.settings.host_notes
      )

  @doc """
  Writes the host's description into the VM's inbox.
  """
  def write_host(state) do
    Inbox.write_host(inbox_dir(state), host_text(state))
    state
  rescue
    error ->
      Logger.error("could not write host.md: #{Exception.message(error)}", system: :sandbox)
      state
  end

  @doc """
  Starts looking at which tools this machine has, in a task.
  """
  def probe_host(state) do
    state
    |> change(:host, &%{&1.host | probing?: true})
    |> task(:probe_host, &HostInfo.probe_tools/0)
  end

  @doc """
  The sandbox's CA certificate, as PEM.
  """
  def ca_pem(state), do: CertificateAuthority.pem(state.ca.cert)

  @doc """
  Puts `grant` in the place of the one with its id, and tells the pages.
  """
  def replace_grant(state, grant) do
    change(
      state,
      :grants,
      &Enum.map(&1.grants, fn g -> if g.id == grant.id, do: grant, else: g end)
    )
  end

  @doc """
  Puts `approval` in the place of the one with its id, and tells the pages.
  """
  def replace_approval(state, approval) do
    change(
      state,
      :approvals,
      &Enum.map(&1.approvals, fn a -> if a.id == approval.id, do: approval, else: a end)
    )
  end

  @doc """
  Counts one more use of a grant, now.
  """
  def used(state, grant_id) do
    case Enum.find(state.grants, &(&1.id == grant_id)) do
      nil ->
        state

      grant ->
        state |> replace_grant(%{grant | uses: grant.uses + 1, last_used_at: now()}) |> changed()
    end
  end

  @doc """
  Applies `fun` to the state under `area` and tells the pages.
  """
  def change(state, area, fun) do
    before = waiting_count(state)
    state = Map.put(state, area, fun.(state))
    broadcast(state, {:sandbox_changed, area})
    # Notifications follow the approvals.
    state = if area in [:approvals, :settings], do: sync_notices(state), else: state
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

  @doc """
  Events are newest first, so the ones older than `id` come after it. An
  id no longer kept leaves nothing older.
  """
  def older_than(events, nil), do: events

  def older_than(events, id),
    do: events |> Stream.drop_while(&(&1.id != id)) |> Stream.drop(1)

  # One notification per waiting approval and stage: shown when it starts
  # waiting, closed when it stops. One you dismissed isn't shown again.
  defp sync_notices(state) do
    wanted =
      if state.settings.desktop_notifications,
        do: for(%Approval{status: :waiting} = a <- state.approvals, into: %{}, do: {a.id, a}),
        else: %{}

    for {id, approval} <- wanted, Map.get(state.notified, id) != approval.stage do
      Notifications.show(
        {:sandbox, state.username, id},
        DesktopNotice.notice(state.username, approval, grant_of(state, approval))
      )
    end

    for id <- Map.keys(state.notified),
        not is_map_key(wanted, id),
        do: Notifications.close({:sandbox, state.username, id})

    %{state | notified: Map.new(wanted, fn {id, approval} -> {id, approval.stage} end)}
  end

  @doc """
  Adds an event to the activity log, newest first, and tells the pages. The log keeps the last 1,000.
  """
  def log(state, attrs) do
    event = struct!(Event, Map.merge(%{id: "event-" <> unique(), at: now()}, attrs))
    broadcast(state, {:sandbox_event, event})
    %{state | events: Enum.take([event | state.events], @event_limit)}
  end

  @doc """
  Sends `message` to this identity's pages.
  """
  def broadcast(state, message),
    do: Phoenix.PubSub.broadcast(MDTClient.PubSub, topic(state.username), message)

  @doc """
  How many approvals wait for you.
  """
  def waiting_count(state), do: Enum.count(state.approvals, &(&1.status == :waiting))

  @doc """
  Runs `fun` in a task whose result comes back to the server as a message, remembered under `purpose`.
  """
  def task(state, purpose, fun) do
    %Task{ref: ref} = Task.Supervisor.async_nolink(@tasks, fun)
    %{state | tasks: Map.put(state.tasks, ref, purpose)}
  end

  @doc """
  The folder the VM sees at `/mnt/mdt`.
  """
  def inbox_dir(state), do: Path.join(state.dir, "inbox")

  @doc """
  Writes the VM's inbox again from the grants as they are: placeholders, files, instructions, the host's description.
  """
  def write_inbox(state) do
    Inbox.write(inbox_dir(state), state.grants, state.values, ca_pem(state))
    write_host(state)
  rescue
    error ->
      Logger.error("could not write the sandbox inbox: #{Exception.message(error)}",
        system: :sandbox
      )

      state
  end

  @doc """
  A timer for the grant's own end and one for each timed allowance. When
  one fires, `sweep/1` reads the clock.
  """
  def schedule_expiry(%Grant{} = grant) do
    if grant.state == :on and grant.expires_at,
      do: timer({:expire_grant, grant.id, grant.expires_at}, grant.expires_at)

    for %Allowance{until: %DateTime{} = until, id: id} <- grant.allowances,
        do: timer({:expire_allowance, grant.id, id}, until)

    :ok
  end

  @doc """
  Sends `message` to the server at `at`.
  """
  def timer(message, %DateTime{} = at) do
    Process.send_after(self(), message, max(DateTime.diff(at, now(), :millisecond), 0))
  end

  @doc """
  Marks the state for saving: it is written a moment later, once for every change in between.
  """
  def changed(%{flush: nil} = state),
    do: %{state | flush: Process.send_after(self(), :flush, @flush_after)}

  def changed(state), do: state

  @doc """
  Writes what outlives a lock, sealed with the vault key.
  """
  def persist(state) do
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
        handoffs: state.handoffs,
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

  @doc """
  Reads what `persist/1` wrote, brought up to date when an older MDT wrote it. A file that can't be opened is set aside, and the sandbox starts empty.
  """
  def restore(path, key, username) do
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

  @doc """
  A length of time as the log says it: `for 30 min`, `until turned off`.
  """
  def duration_words(:until_off), do: "until turned off"

  def duration_words(:grant), do: "while the grant is on"

  def duration_words(60), do: "for 1 h"

  def duration_words(minutes) when rem(minutes, 60) == 0, do: "for #{div(minutes, 60)} h"

  def duration_words(minutes), do: "for #{minutes} min"

  @doc """
  A short id not used before in this run.
  """
  def unique, do: Integer.to_string(System.unique_integer([:positive]), 36) |> String.downcase()

  @doc """
  The time, to the second.
  """
  def now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
