defmodule MDTClient.Sandbox.Server.Approvals do
  @moduledoc """
  What waits for you, in the sandbox server's state: holding a use or an
  agent's ask as an approval, joining a retry to the one already waiting,
  your decision and what it sets off, giving up when the time runs out, and
  answering everyone who was held.

  A use is decided before it gets here (`MDTClient.Sandbox.Policy`); this is
  what happens when the answer was "ask". Runs in the server's process
  (`MDTClient.Sandbox.Server.State`).
  """

  alias MDTClient.Sandbox.{Approval, Grant, HostRun, Shown}
  alias MDTClient.Sandbox.Server.{Grants, HostRuns, State, Values}

  @history_limit 100
  # An agent's ask waits this long for you; the agent itself waits less and
  # comes back with `mdt wait`.
  @activation_hold_seconds 30 * 60
  @max_waiting_activations 10

  @doc """
  Joins a waiting approval for the very same use, so a client's retries
  are one decision, or starts a new one. "The same" is `join`, not the
  pattern: a request with another body or query is another card, since a
  decision covers what its card shows.
  """
  def hold(state, approval, waiter) do
    case Enum.find(state.approvals, fn other ->
           other.status == :waiting and other.grant_id == approval.grant_id and
             other.kind == approval.kind and other.join == approval.join
         end) do
      %Approval{} = waiting ->
        state
        |> State.replace_approval(%{waiting | retries: waiting.retries + 1})
        |> add_waiter(waiting.id, waiter)

      nil ->
        Process.send_after(
          self(),
          {:give_up, approval.id, approval.deadline},
          max(DateTime.diff(approval.deadline, State.now(), :millisecond), 0)
        )

        state
        |> add_waiter(approval.id, waiter)
        |> State.change(:approvals, &[approval | &1.approvals])
    end
  end

  @doc """
  Everything MDT read of a request: its method, host, full target, how
  long its body says it is, and the body read so far (all of it up to 64
  KiB).
  """
  def request_digest(request) do
    :crypto.hash(
      :sha256,
      :erlang.term_to_binary({
        request.method,
        request.host,
        request.path,
        for(
          {name, value} <- request.headers,
          name in ["content-length", "transfer-encoding"],
          do: {name, value}
        ),
        request.body
      })
    )
  end

  @doc """
  Holds one more caller on an approval, to be answered when it is decided.
  """
  def add_waiter(state, approval_id, waiter),
    do:
      Map.update!(
        state,
        :waiters,
        &Map.update(&1, approval_id, [waiter], fn list -> list ++ [waiter] end)
      )

  @doc """
  Which decisions fit which approval: activations are answered by turning
  a grant on (or setting one up), uses by letting them through.
  """
  def fits?(%Approval{kind: :activation, grant_id: nil}, decision, state) do
    case decision do
      {:set_up, grant_id} -> Enum.any?(state.grants, &(&1.id == grant_id))
      :decline -> true
      _other -> false
    end
  end

  def fits?(%Approval{kind: :activation}, decision, _state) do
    case decision do
      {:turn_on, minutes, uses} -> uses in [:ask, :all] and duration?(minutes, :until_off)
      :decline -> true
      _other -> false
    end
  end

  def fits?(%Approval{kind: :command, stage: :run}, decision, _state) do
    case decision do
      {:run, output_to} -> output_to in [:send, :review]
      :decline -> true
      _other -> false
    end
  end

  def fits?(%Approval{kind: :command, stage: :output}, decision, _state),
    do: decision in [:send_output, :keep_output]

  def fits?(%Approval{}, decision, _state) do
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

  @doc """
  Carries out your decision on a waiting approval. `fits?/3` says which decisions an approval takes.
  """
  def decide(state, approval, {:turn_on, minutes, uses}) do
    grant = Enum.find(state.grants, &(&1.id == approval.grant_id))

    state
    |> settle(approval, :allowed, {:turn_on, minutes, uses})
    |> Grants.turn_on(grant, minutes, uses, " · asked by #{approval.agent}")
    |> answer_waiters(approval, :allow)
  end

  def decide(state, approval, {:set_up, grant_id}) do
    grant = Enum.find(state.grants, &(&1.id == grant_id))
    approval = %{approval | grant_id: grant_id}
    minutes = approval.minutes

    state
    |> State.replace_approval(approval)
    |> settle(approval, :allowed, {:set_up, grant_id})
    |> Grants.turn_on(grant, minutes, :ask, " · asked by #{approval.agent}")
    |> answer_waiters(approval, :allow)
  end

  def decide(state, approval, {:run, output_to}) do
    run = %{
      state: :running,
      output_to: output_to,
      started_at: State.now(),
      finished_at: nil,
      exit: nil,
      output: "",
      bytes: 0,
      cut: 0,
      stopped: false,
      timed_out: false,
      error: nil
    }

    approval = %{approval | run: run}
    server = self()
    id = approval.id
    job = %{script: approval.script, dir: approval.dir, timeout: approval.timeout}

    state
    |> settle(approval, :allowed, {:run, output_to})
    |> State.log(
      HostRuns.command_event(approval, "you ran it" <> HostRuns.output_words(output_to))
    )
    |> State.task({:command, id}, fn ->
      HostRun.run(job, fn group -> send(server, {:command_started, id, group}) end)
    end)
  end

  def decide(state, approval, :send_output) do
    state
    |> settle(approval, :allowed, :send_output)
    |> answer_waiters(approval, :allow)
    |> State.log(HostRuns.command_event(approval, "you sent its output to the agent"))
  end

  def decide(state, approval, :keep_output) do
    state
    |> settle(approval, :denied, :keep_output)
    |> answer_waiters(approval, {:deny, :by_you})
    |> State.log(HostRuns.command_event(approval, "you kept its output from the agent"))
  end

  def decide(state, approval, :decline) do
    state
    |> settle(approval, :denied, :decline)
    |> answer_waiters(approval, {:deny, :by_you})
    |> State.log(event_for(approval, :denied, "you declined"))
  end

  def decide(state, approval, :allow_once) do
    state
    |> settle(approval, :allowed, :allow_once)
    |> answer_waiters(approval, :allow)
    |> State.log(event_for(approval, :allowed, "you allowed once"))
  end

  def decide(state, approval, {:allow, scope, duration}) do
    case Enum.find(state.grants, &(&1.id == approval.grant_id)) do
      nil ->
        decide(state, approval, :allow_once)

      grant ->
        pattern = if scope == :all, do: :all, else: approval.pattern

        state
        |> Grants.allow(grant, pattern, duration)
        |> State.log(%{
          outcome: :grant,
          summary:
            if(scope == :all,
              do: "#{grant.name}: every use allowed #{State.duration_words(duration)}",
              else:
                "#{grant.name}: uses like “#{approval.title}” allowed #{State.duration_words(duration)}"
            ),
          grant_id: grant.id
        })
    end
  end

  def decide(state, approval, :deny) do
    state
    |> settle(approval, :denied, :deny)
    |> answer_waiters(approval, {:deny, :by_you})
    |> State.log(event_for(approval, :denied, "you denied"))
  end

  def decide(state, approval, :deny_and_turn_off) do
    state =
      state
      |> settle(approval, :denied, :deny_and_turn_off)
      |> answer_waiters(approval, {:deny, :by_you})
      |> State.log(event_for(approval, :denied, "you denied"))

    case Enum.find(state.grants, &(&1.id == approval.grant_id)) do
      nil ->
        state

      grant ->
        state
        |> settle_waiting(grant.id, :grant_off)
        |> State.replace_grant(%{grant | state: :off, expires_at: nil, allowances: []})
        |> State.log(%{
          outcome: :grant,
          summary: "#{grant.name} turned off from an approval",
          grant_id: grant.id
        })
        |> State.write_inbox()
        |> State.changed()
    end
  end

  @doc """
  Turning a grant on yourself answers the agents waiting for it.
  """
  def settle_activations(state, grant_id, minutes, uses) do
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

  @doc """
  Answers everyone held on `approval`: the proxy's connections and
  requests, and agents waiting through the channel.
  """
  def answer_waiters(state, approval, outcome) do
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
        if outcome == :allow, do: State.used(acc, approval.grant_id), else: acc

      {from, {:request, request}}, acc ->
        case {outcome, grant} do
          {:allow, %Grant{}} ->
            Values.forward(acc, grant, request, from)

          {{:deny, :timed_out}, _} ->
            GenServer.reply(
              from,
              Values.deny(403, "mdt_approval_timeout", "Nobody decided in time.", grant)
            )

            acc

          {{:deny, :grant_off}, _} ->
            GenServer.reply(
              from,
              Values.deny(403, "mdt_grant_off", "The grant turned off while this waited.", grant)
            )

            acc

          _denied ->
            GenServer.reply(
              from,
              Values.deny(403, "mdt_denied_by_user", "The user denied this request.", grant)
            )

            acc
        end
    end)
  end

  @doc """
  What an agent asked for, checked: a grant that exists (by id, or by name
  in any case), or a `need` no grant meets yet.
  """
  def activation(state, ask) do
    # An ask is the VM's: what isn't text counts as nothing.
    reason = ask |> Map.get(:reason) |> Shown.text() |> String.trim() |> String.slice(0, 1_000)
    agent = ask |> Map.get(:agent) |> Shown.text() |> String.trim() |> String.slice(0, 60)
    agent = if agent == "", do: "An agent", else: agent
    minutes = Map.get(ask, :minutes) || 60
    wanted = ask |> Map.get(:grant) |> State.to_text() |> String.trim()
    need = ask |> Map.get(:need) |> Shown.text() |> String.trim() |> String.slice(0, 400)

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
           id: "ask-" <> State.unique(),
           kind: :activation,
           grant_id: grant && grant.id,
           title:
             if(grant,
               do: "Turn on #{grant.name}",
               else: "Access you haven't set up"
             ),
           agent: agent,
           thread: Approval.thread(ask),
           minutes: minutes,
           need: if(grant, do: nil, else: need),
           reason: reason,
           pattern: pattern,
           requested_at: State.now(),
           deadline: DateTime.add(State.now(), @activation_hold_seconds, :second),
           claims: [{"Reason", reason}]
         }}
    end
  end

  @doc """
  One waiting ask per grant (and per described need): asking again joins it.
  """
  def hold_activation(state, approval) do
    case Enum.find(state.approvals, fn other ->
           other.status == :waiting and other.kind == :activation and
             other.pattern == approval.pattern
         end) do
      %Approval{} = waiting ->
        joined = %{waiting | retries: waiting.retries + 1}
        {State.replace_approval(state, joined), joined}

      nil ->
        Process.send_after(
          self(),
          {:give_up, approval.id, approval.deadline},
          @activation_hold_seconds * 1_000
        )

        {State.change(state, :approvals, &[approval | &1.approvals]), approval}
    end
  end

  @doc """
  Ends an approval nobody decided in time, and tells everyone held on it.
  """
  def give_up(state, %Approval{kind: :command, stage: :output} = approval) do
    state
    |> settle(approval, :timed_out, nil)
    |> answer_waiters(approval, {:deny, :timed_out})
    |> State.log(HostRuns.command_event(approval, "output kept: you didn't release it in time"))
  end

  def give_up(state, approval) do
    minutes = approval.deadline |> DateTime.diff(approval.requested_at) |> div(60) |> max(1)

    state
    |> settle(approval, :timed_out, nil)
    |> answer_waiters(approval, {:deny, :timed_out})
    |> State.log(event_for(approval, :timed_out, "gave up after #{minutes} min"))
  end

  @doc """
  Marks an approval decided. The history keeps the last 100, and a command still running stays in sight whatever is decided meanwhile.
  """
  def settle(state, approval, status, decision) do
    approval = %{approval | status: status, decision: decision, decided_at: State.now()}

    State.change(state, :approvals, fn state ->
      {waiting, decided} =
        state.approvals
        |> Enum.map(&if(&1.id == approval.id, do: approval, else: &1))
        |> Enum.split_with(&(&1.status == :waiting))

      # A running command stays whatever is decided meanwhile.
      {running, history} = Enum.split_with(decided, &Approval.running?/1)

      waiting ++
        running ++
        Enum.take(Enum.sort_by(history, & &1.decided_at, {:desc, DateTime}), @history_limit)
    end)
  end

  @doc """
  Denies every use waiting on a grant, as when the grant turns off.
  """
  def settle_waiting(state, grant_id, decision, kinds \\ [:request, :connection]) do
    state.approvals
    |> Enum.filter(&(&1.status == :waiting and &1.grant_id == grant_id and &1.kind in kinds))
    |> Enum.reduce(state, fn approval, acc ->
      acc
      |> settle(approval, :denied, decision)
      |> answer_waiters(approval, {:deny, :grant_off})
      |> State.log(event_for(approval, :refused, "its grant turned off"))
    end)
  end

  @doc """
  The log's event for what became of an approval.
  """
  def event_for(%Approval{kind: :command} = approval, _outcome, how),
    do: HostRuns.command_event(approval, how)

  def event_for(approval, outcome, how) do
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
end
