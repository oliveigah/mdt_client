defmodule MDTClient.Sandbox.Server.HostRuns do
  @moduledoc """
  Commands on this machine, in the sandbox server's state: an agent's ask
  checked against its command grant and held as an approval, the run once
  you approve it, its output and how it ended, and stopping it.

  `MDTClient.Sandbox.HostCommand` checks and describes an ask and
  `MDTClient.Sandbox.HostRun` runs one; this keeps the server's record of
  both. Runs in the server's process (`MDTClient.Sandbox.Server.State`).
  """

  alias MDTClient.Sandbox.{Approval, HostRun, Policy}
  alias MDTClient.Sandbox.Server.{Approvals, State}

  # A command waits as long for your go-ahead, and once it ran with its
  # output for you, as long again for you to release it.
  @command_hold_seconds 30 * 60
  @max_waiting_commands 10

  @doc """
  The command grant an ask goes through. None exists until you add one,
  so a new identity runs nothing on your machine for the VM. A grant with a
  script of yours runs that text, in its folder, and takes none from the
  agent.
  """
  def command_grant(state, ask) do
    case Policy.decide(Policy.snapshot(state.grants), {:command, ask}, State.now()) do
      {:ask, grant, %{script: nil}} -> {:ok, grant, ask, []}
      {:ask, grant, about} -> {:ok, grant, %{ask | script: about.script}, [folder: about.dir]}
      {:refuse, {:grant_off, grant}} -> {:error, {:grant_off, grant.id}}
      {:refuse, {:fixed_script, grant}} -> {:error, {:fixed_script, grant.id}}
      {:refuse, reason} -> {:error, reason}
    end
  end

  @doc """
  The approval a checked command waits as, unless ten already wait.
  """
  def command_approval(state, checked, grant) do
    waiting =
      Enum.filter(state.approvals, &(&1.status == :waiting and &1.kind == :command))

    if length(waiting) >= @max_waiting_commands and
         not Enum.any?(waiting, &(&1.pattern == checked.pattern)) do
      {:error, :too_many}
    else
      {:ok,
       %Approval{
         id: "run-" <> State.unique(),
         kind: :command,
         grant_id: grant.id,
         title: checked.title,
         agent: checked.agent,
         thread: checked.thread,
         reason: checked.reason,
         script: checked.script,
         dir: checked.dir,
         timeout: checked.timeout,
         pattern: checked.pattern,
         facts:
           [
             {"Grant", grant.name},
             {"Script",
              if(grant.script,
                do: "Yours, as set on the grant",
                else: "The agent's, exactly as shown"
              )}
           ] ++ checked.facts,
         hints: checked.hints,
         claims: [{"Reason", checked.reason}],
         requested_at: State.now(),
         deadline: DateTime.add(State.now(), @command_hold_seconds, :second)
       }}
    end
  end

  @doc """
  The same script, directory and limit as one waiting for its go-ahead
  joins it.
  """
  def hold_command(state, approval) do
    case Enum.find(state.approvals, fn other ->
           other.status == :waiting and other.kind == :command and other.stage == :run and
             other.pattern == approval.pattern
         end) do
      %Approval{} = waiting ->
        joined = %{waiting | retries: waiting.retries + 1}
        {State.replace_approval(state, joined), joined}

      nil ->
        Process.send_after(
          self(),
          {:give_up, approval.id, approval.deadline},
          @command_hold_seconds * 1_000
        )

        {State.change(state, :approvals, &[approval | &1.approvals]), approval}
    end
  end

  @doc """
  Takes a run's result: the output goes to the agent, or waits for you first when you asked to see it.
  """
  def finished_command(state, approval_id, result) do
    state = %{state | running: Map.delete(state.running, approval_id)}

    case Enum.find(state.approvals, &(&1.id == approval_id)) do
      %Approval{run: %{state: :running} = run} = approval ->
        run =
          Map.merge(run, %{
            state: :done,
            finished_at: State.now(),
            exit: result[:exit],
            output: result[:output] || "",
            bytes: result[:bytes] || 0,
            cut: result[:cut] || 0,
            timed_out: result[:timed_out] || false,
            error: result[:error]
          })

        approval = %{approval | run: run}
        state = State.log(state, command_event(approval, ended_words(run)))

        # A command that couldn't start has no output worth holding.
        case if(run.error, do: :send, else: run.output_to) do
          :send ->
            state
            |> State.replace_approval(approval)
            |> Approvals.answer_waiters(approval, :allow)

          :review ->
            deadline = DateTime.add(State.now(), @command_hold_seconds, :second)

            Process.send_after(
              self(),
              {:give_up, approval.id, deadline},
              @command_hold_seconds * 1_000
            )

            state
            |> State.replace_approval(%{
              approval
              | status: :waiting,
                stage: :output,
                deadline: deadline,
                decided_at: nil
            })
        end

      _gone ->
        state
    end
  end

  @doc """
  Signals a running command's process group; one that hasn't reported its group yet is stopped as soon as it does.
  """
  def stop_group(state, approval_id, signal) do
    case state.running do
      %{^approval_id => group} when is_integer(group) ->
        HostRun.stop(group, signal)
        state

      %{^approval_id => :stop} ->
        state

      _not_started when signal == "TERM" ->
        # Not reported yet: stopped as soon as it is.
        if Enum.any?(state.approvals, &(&1.id == approval_id and Approval.running?(&1))),
          do: put_in(state.running[approval_id], :stop),
          else: state

      _ended ->
        state
    end
  end

  @doc """
  The log's event for something that happened to a command.
  """
  def command_event(approval, how) do
    %{outcome: :command, summary: "#{approval.title} · #{how}"}
  end

  @doc """
  Where a run's output goes, in the log's words.
  """
  def output_words(:send), do: ", output to the agent"

  def output_words(:review), do: ", output to you first"

  defp ended_words(%{error: error}) when is_binary(error),
    do: "couldn't start: #{String.slice(error, 0, 120)}"

  defp ended_words(run) do
    seconds = DateTime.diff(run.finished_at, run.started_at)

    cond do
      run.stopped -> "stopped by you after #{seconds} s (exit #{run.exit})"
      run.timed_out -> "hit its time limit (exit #{run.exit})"
      true -> "exit #{run.exit} after #{seconds} s"
    end
  end
end
