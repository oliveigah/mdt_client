defmodule MDTClient.Sandbox.Channel do
  @moduledoc """
  How agents in the VM ask MDT for access: a Unix socket that microsandbox
  joins to the VM's vsock port 5000 (`msb create --vsock`). The VM has no
  network route to MDT, so this is the only way in, and all it offers is
  reading the grants and the host's description, asking for a grant, and
  asking to run a command on the host.

  Inside the VM, `/mnt/mdt/bin/mdt` (`priv/sandbox/mdt-cli`) speaks it with
  socat, one ask per connection:

    * the client sends one line of JSON: `{"command": "grants"}`,
      `{"command": "host"}`, `{"command": "request", "grant": "...",
      "need": "...", "minutes": 60, "reason": "...", "agent": "...",
      "wait": 60}`, `{"command": "run", "script": "...", "dir": "...",
      "timeout": 120, "reason": "...", "agent": "...", "wait": 60}` or
      `{"command": "wait", "id": "...", "wait": 60}`;
    * MDT answers with the exit status the command should end with on the
      first line, then text for the agent, and closes.

  Exit statuses for grants: 0 the grant is on, 1 something is wrong with the
  ask, 2 still waiting for the user, 3 declined or given up. The command
  itself uses 4 when MDT doesn't answer: locked, or not running.

  A command that ran answers `ran STATUS` on the first line, a note for the
  agent's stderr on the second (often empty), then the output. MDT's own
  outcomes for runs use statuses commands rarely use: 120 still waiting,
  121 it didn't run or its output didn't come back, 122 something is wrong
  with the ask, and the command itself uses 123 when MDT doesn't answer.
  Asks to run have ids starting with `run-`, so `mdt wait` knows which set
  of statuses applies.

  An ask waits for you as an activation approval (`MDTClient.Sandbox.Approval`)
  for 30 minutes; the agent waits at most `"wait"` seconds of it, then hears
  it is still pending and can come back with `mdt wait`. Any process in the
  VM can ask, which is accepted: all it can do is ask. The server keeps one
  waiting ask per grant and ten in all.

  One listener per unlocked identity. Microsandbox opens the socket for each
  connection, so when MDT restarts, the channel works again without touching
  the VM.
  """

  use GenServer

  require Logger

  alias MDTClient.Accounts
  alias MDTClient.Sandbox.{Approval, Grant, HostCommand, Instructions, Server}
  alias MDTClient.Vault.Store

  @port 5000
  @line_limit 64 * 1024
  @read_timeout 10_000
  @default_wait 60
  @max_wait 600

  @run_waiting 120
  @run_not_done 121
  @run_wrong 122
  @run_unreachable 123

  @doc "The vsock port agents connect to inside the VM."
  @spec port() :: pos_integer()
  def port, do: @port

  @doc """
  The host socket of one identity's channel. Unix socket paths are short
  (108 bytes), so it sits in the runtime directory rather than the
  identity's folder, named by the start of the identity's id.
  """
  @spec socket_path(String.t()) :: Path.t()
  def socket_path(username) do
    Path.join(dir(), "mdt-sandbox-" <> String.slice(Accounts.id(username), 0, 12) <> ".sock")
  end

  defp dir do
    config = Application.get_env(:mdt_client, Server, [])

    Keyword.get_lazy(config, :channel_dir, fn ->
      case System.get_env("XDG_RUNTIME_DIR") do
        runtime when is_binary(runtime) and runtime != "" -> Path.join(runtime, "mdt")
        _ -> Path.join(System.tmp_dir!(), "mdt-#{System.get_env("USER", "user")}")
      end
    end)
  end

  @doc "Starts the channel of one unlocked identity."
  def start_link(opts) do
    username = Keyword.fetch!(opts, :username)
    GenServer.start_link(__MODULE__, username, name: Store.via(__MODULE__, username))
  end

  @doc false
  def child_spec(opts) do
    %{id: {__MODULE__, Keyword.fetch!(opts, :username)}, start: {__MODULE__, :start_link, [opts]}}
  end

  @impl true
  def init(username) do
    Process.flag(:trap_exit, true)
    path = socket_path(username)
    File.mkdir_p!(Path.dirname(path))
    File.chmod(Path.dirname(path), 0o700)
    File.rm(path)

    case :gen_tcp.listen(0, [
           :binary,
           ifaddr: {:local, path},
           active: false,
           packet: :line,
           packet_size: @line_limit,
           backlog: 64
         ]) do
      {:ok, socket} ->
        File.chmod(path, 0o600)
        acceptor = spawn_link(fn -> accept(socket, username) end)
        {:ok, %{username: username, path: path, socket: socket, acceptor: acceptor}}

      {:error, reason} ->
        # The VM loses only its way to ask; everything else keeps working.
        Logger.warning("sandbox channel could not listen on #{path}: #{inspect(reason)}",
          system: :sandbox
        )

        {:ok, %{username: username, path: path, socket: nil, acceptor: nil}}
    end
  end

  @impl true
  def handle_info({:EXIT, pid, reason}, %{acceptor: pid} = state) do
    {:stop, reason, state}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.socket, do: :gen_tcp.close(state.socket)
    File.rm(state.path)
    :ok
  end

  defp accept(socket, username) do
    case :gen_tcp.accept(socket) do
      {:ok, client} ->
        case Task.Supervisor.start_child(MDTClient.Sandbox.TaskSupervisor, fn ->
               receive do
                 {:go, client} -> serve(client, username)
               after
                 5_000 -> :ok
               end
             end) do
          {:ok, pid} ->
            :ok = :gen_tcp.controlling_process(client, pid)
            send(pid, {:go, client})

          {:error, _reason} ->
            :gen_tcp.close(client)
        end

        accept(socket, username)

      {:error, :closed} ->
        exit(:normal)

      {:error, reason} ->
        exit(reason)
    end
  end

  @doc false
  # One ask: a line of JSON in, an exit status and text out.
  def serve(client, username) do
    ask =
      case :gen_tcp.recv(client, 0, @read_timeout) do
        {:ok, line} ->
          case Jason.decode(line) do
            {:ok, %{"command" => command} = ask} when is_binary(command) -> ask
            _ -> :unreadable
          end

        {:error, _reason} ->
          :none
      end

    reply =
      try do
        case ask do
          :unreadable -> {1, "MDT couldn't read that ask. Use the mdt command."}
          :none -> {1, "MDT got no ask."}
          %{"command" => command} -> answer(command, ask, username)
        end
      catch
        :exit, _locked ->
          status = if run?(ask), do: @run_unreachable, else: 4
          {status, "MDT is locked. Ask the user to unlock it."}
      end

    :gen_tcp.send(client, encode(reply))
    :gen_tcp.close(client)
  end

  # The output ends with a dot, so a shell reading it with `$(...)` keeps
  # its trailing newlines; the mdt command takes the dot off.
  defp encode({{:ran, status}, note, output}), do: "ran #{status}\n#{note}\n#{output}."
  defp encode({status, text}), do: "#{status}\n#{String.trim_trailing(text)}\n"

  defp run?(%{"command" => "run"}), do: true
  defp run?(%{"command" => "wait", "id" => "run-" <> _}), do: true
  defp run?(_ask), do: false

  @doc """
  The answer to one ask, as `{exit_status, text}`. Public for the tests,
  which ask without a socket.
  """
  @spec answer(String.t(), map(), String.t()) ::
          {non_neg_integer(), String.t()} | {{:ran, integer()}, String.t(), String.t()}
  def answer("grants", _ask, username) do
    grants = Server.call(username, :agent_grants)
    {0, Instructions.grants(grants, DateTime.utc_now())}
  end

  def answer("host", _ask, username), do: {0, Server.call(username, :host_text)}

  def answer("run", ask, username) do
    request = %{
      script: ask["script"],
      dir: ask["dir"],
      timeout: ask["timeout"],
      reason: ask["reason"],
      agent: ask["agent"]
    }

    case Server.call(username, {:request_command, request}) do
      {:ok, approval} -> await(username, approval.id, wait(ask))
      {:error, reason} -> {@run_wrong, run_refusal(reason)}
    end
  end

  def answer("request", ask, username) do
    request = %{
      grant: ask["grant"],
      need: ask["need"],
      minutes: ask["minutes"],
      reason: ask["reason"],
      agent: ask["agent"]
    }

    case Server.call(username, {:request_access, request}) do
      {:ok, approval} ->
        await(username, approval.id, wait(ask))

      {:already_on, grant} ->
        {0, "#{grant.name} is already on #{until(grant)}. #{uses(grant)}"}

      {:error, reason} ->
        {1, refusal(reason, ask)}
    end
  end

  def answer("wait", %{"id" => id} = ask, username) when is_binary(id),
    do: await(username, id, wait(ask))

  def answer(_command, _ask, _username),
    do: {1, "MDT knows these commands: grants, host, request, run, wait. Run mdt help."}

  defp await(username, id, seconds) do
    ms = seconds * 1_000

    case Server.call(username, {:await, id, ms}, ms + 5_000) do
      {:pending, %Approval{kind: :command} = approval} -> run_pending(id, approval)
      {:pending, _approval} -> pending(id)
      {:ok, %Approval{kind: :command} = approval, _grant} -> ran(approval)
      {:ok, approval, grant} -> settled(approval, grant)
      {:error, :not_found} -> not_found(id)
    end
  end

  defp not_found("run-" <> _ = id),
    do: {@run_not_done, "No run #{id} is known. MDT forgets asks when it restarts."}

  defp not_found(id), do: {1, "No ask #{id} is known. MDT forgets asks when it restarts."}

  defp run_pending(id, approval) do
    what =
      case approval do
        %Approval{status: :waiting, stage: :output} ->
          "It ran; the user is looking at its output before it comes back to you."

        %Approval{run: %{state: :running}} ->
          "The user approved it, and it is running on their machine."

        %Approval{} ->
          "Still waiting for the user to approve it."
      end

    {@run_waiting,
     """
     #{what} Keep working on what doesn't need it, then run: mdt wait #{id}
     """}
  end

  # The final answer to an ask to run: the command's own status and output,
  # or why there is none.
  defp ran(%Approval{status: :allowed, run: %{state: :done, error: nil} = run}) do
    note =
      [
        run.stopped && "the user stopped it",
        run.timed_out && "it hit its time limit",
        run.cut > 0 && "#{run.cut} bytes of output were cut from the middle"
      ]
      |> Enum.filter(&is_binary/1)
      |> case do
        [] -> ""
        notes -> "mdt: ran on the user's machine; " <> Enum.join(notes, ", ") <> "."
      end

    {{:ran, run.exit}, note, String.replace(run.output, <<0>>, "")}
  end

  defp ran(%Approval{run: %{state: :done, error: error}}) when is_binary(error),
    do: {@run_not_done, "It couldn't start on the user's machine: #{error}"}

  defp ran(%Approval{status: :denied, decision: :keep_output, run: run}),
    do:
      {@run_not_done,
       "It ran (exit #{run.exit}), but the user kept its output from you. Ask them about it if you need it."}

  defp ran(%Approval{status: :timed_out, stage: :output, run: run}),
    do:
      {@run_not_done,
       "It ran (exit #{run.exit}), but the user didn't release its output in 30 minutes. Ask them about it if you need it."}

  defp ran(%Approval{status: :denied}),
    do:
      {@run_not_done,
       "The user declined to run it. Don't ask again for the same thing unless they say so."}

  defp ran(%Approval{status: :timed_out}),
    do:
      {@run_not_done,
       "The user didn't answer in 30 minutes. Tell them what you need to run, then ask again."}

  defp pending(id) do
    {2,
     """
     Still waiting for the user (ask #{id}). Keep working on what doesn't need it, then run: mdt wait #{id}
     The ask stays for 30 minutes.
     """}
  end

  defp settled(%Approval{status: :allowed}, %Grant{} = grant) do
    {0,
     """
     #{grant.name} is on #{until(grant)}. #{uses(grant)}
     #{Instructions.usage(grant)}
     """}
  end

  defp settled(%Approval{status: :denied, decision: :grant_off}, _grant),
    do: {3, "The grant was removed while you waited."}

  defp settled(%Approval{status: :denied}, _grant),
    do: {3, "The user declined. Don't ask again for the same thing unless they say so."}

  defp settled(%Approval{status: :timed_out}, _grant),
    do: {3, "The user didn't answer in 30 minutes. Tell them what you need, then ask again."}

  defp settled(%Approval{}, nil), do: {3, "The grant no longer exists."}

  defp until(%Grant{expires_at: nil}), do: "until the user turns it off"

  defp until(%Grant{expires_at: at}),
    do: "until #{Calendar.strftime(at, "%H:%M")} UTC"

  defp uses(%Grant{kind: :file}), do: "The file is there while it stays on."

  defp uses(%Grant{} = grant) do
    if Enum.any?(grant.allowances, &(&1.pattern == :all)),
      do: "Every use goes through without asking.",
      else:
        "Each use still waits for the user's approval, so a request can hang for a few minutes: wait, don't retry in a loop."
  end

  defp refusal(:unknown_grant, ask) do
    """
    No grant is called "#{ask["grant"]}". Run mdt grants to see them. To ask for access none of them gives:
      mdt request --need "the access, and the service or host it is for" --reason "why"
    """
  end

  defp refusal(:no_reason, _ask),
    do: ~s[Say why: --reason "what you are about to do with it". The user reads it.]

  defp refusal(:bad_minutes, _ask), do: "--minutes is from 1 to 1440."

  defp refusal(:nothing_asked, _ask),
    do: ~s[Name a grant (mdt request GRANT --reason "...") or describe a need (--need "...").]

  defp refusal(:too_many, _ask),
    do: "Ten asks already wait for the user. Wait for their answers first (mdt wait ID)."

  defp run_refusal(:no_reason),
    do:
      ~s[Say why: --reason "what it does, and why it must run on the user's machine". The user reads it.]

  defp run_refusal(:no_script),
    do: "Give the command after --, or the script on stdin. See: mdt help"

  defp run_refusal(:script_too_long),
    do:
      "The script is over #{div(HostCommand.max_script(), 1024)} KiB. Put the long part in a file in a shared folder, and say so in the reason."

  defp run_refusal(:bad_timeout),
    do: "--timeout is from 1 to #{elem(HostCommand.timeouts(), 1)} seconds."

  defp run_refusal(:too_many),
    do: "Ten commands already wait for the user. Wait for their answers first (mdt wait ID)."

  defp wait(ask) do
    case ask["wait"] do
      seconds when is_integer(seconds) and seconds >= 0 -> min(seconds, @max_wait)
      _ -> @default_wait
    end
  end
end
