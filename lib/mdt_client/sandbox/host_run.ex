defmodule MDTClient.Sandbox.HostRun do
  @moduledoc """
  Runs one command you approved on the host, as you, and reports how it
  went. `MDTClient.Sandbox.Server` calls `run/2` in a task once you approve a
  `MDTClient.Sandbox.Approval` of kind `:command`.

    * `bash -lc SCRIPT`, so your login profile sets up your usual tools, in
      the approved directory, with stdin from `/dev/null` and SIGPIPE back
      to its default, which the BEAM ignores;
    * under `timeout`: TERM at the limit, KILL 5 seconds later (exit 124,
      or 137 when it had to be killed). `timeout`
      puts the command in a process group of its own, whose id is the
      operating system pid `run/2` reports, so `stop/2` reaches every
      process the command started;
    * in MDT's environment without MDT's and the BEAM's own variables
      (`scrubbed?/1`), which a command such as `env` would otherwise print;
    * stdout and stderr together; the first and last 32 KiB are kept, and
      what's between is cut and counted. Output is made valid UTF-8, so it
      can be shown and sent as text.

  Only tests set `config :mdt_client, MDTClient.Sandbox.HostRun, home: path`,
  the `HOME` commands see instead of yours (`home_env/0`), so the login
  profile of whoever runs them doesn't add its own output.
  """

  @keep 32 * 1024
  @kill_after 5

  # The BEAM ignores SIGPIPE and its children inherit that, so `seq | head`
  # would end with "write error: Broken pipe" instead of quietly, as in a
  # terminal. Bash can't undo an ignored signal; `env --default-signal`
  # (coreutils 8.31 and later) can, and is skipped where it's missing.
  # `env` and then `timeout` run in place of the outer shell, so the port's
  # pid is timeout's, which leads the command's process group.
  @wrapper "d=; env --default-signal=PIPE true 2>/dev/null && d=--default-signal=PIPE; " <>
             ~s(exec env $d timeout --kill-after=#{@kill_after}s "$1" bash -lc "$2" </dev/null)

  @scrubbed_prefixes ~w(RELEASE_ ERL_ ELIXIR_ ELIXIRKIT_ MIX_ PHX_ MDT_ __MIX)
  @scrubbed ~w(SECRET_KEY_BASE PORT BINDIR ROOTDIR EMU PROGNAME DNS_CLUSTER_QUERY)

  @type job :: %{script: String.t(), dir: String.t(), timeout: pos_integer()}

  @type result :: %{
          exit: integer() | nil,
          output: String.t(),
          bytes: non_neg_integer(),
          cut: non_neg_integer(),
          timed_out: boolean(),
          error: String.t() | nil
        }

  @doc "How many bytes of output are kept from each end."
  @spec keep() :: pos_integer()
  def keep, do: @keep

  @doc """
  Runs `job` and waits for it to end. `started` is called with the
  command's process group id as soon as it runs.
  """
  @spec run(job(), (pos_integer() -> any())) :: result()
  def run(%{script: script, dir: dir, timeout: timeout}, started) do
    if not File.dir?(dir), do: raise("the directory #{dir} doesn't exist on this machine")
    started_at = System.monotonic_time(:millisecond)

    port =
      Port.open({:spawn_executable, System.find_executable("bash") || "/bin/bash"}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        :use_stdio,
        cd: dir,
        env: env(),
        args: ["-c", @wrapper, "mdt-host-command", "#{timeout}s", script]
      ])

    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> started.(pid)
      nil -> :ok
    end

    result = collect(port, %{head: "", tail: "", bytes: 0})

    # `timeout` exits 124 when it is itself stopped too, so only a run that
    # lasted its whole limit timed out.
    elapsed = System.monotonic_time(:millisecond) - started_at
    %{result | timed_out: result.exit in [124, 137] and elapsed >= timeout * 1_000}
  rescue
    error ->
      %{
        exit: nil,
        output: "",
        bytes: 0,
        cut: 0,
        timed_out: false,
        error: Exception.message(error)
      }
  end

  @doc "Sends `signal` (`\"TERM\"` or `\"KILL\"`) to every process of a running command."
  @spec stop(pos_integer(), String.t()) :: :ok
  def stop(group, signal) when signal in ["TERM", "KILL"] do
    System.cmd("kill", ["-#{signal}", "--", "-#{group}"], stderr_to_stdout: true)
    :ok
  end

  @doc "Whether an environment variable is MDT's or the BEAM's own, and so kept from commands."
  @spec scrubbed?(String.t()) :: boolean()
  def scrubbed?(name),
    do: name in @scrubbed or Enum.any?(@scrubbed_prefixes, &String.starts_with?(name, &1))

  @doc """
  The `System.cmd/3` `env` for a login shell MDT starts on the host: nothing,
  so it sees your `HOME`, except in tests, which set a home of their own
  that keeps out the login profile of whoever runs them. Host commands,
  minted values and the tool probe all use it.
  """
  @spec home_env() :: [{String.t(), String.t()}]
  def home_env do
    case Application.get_env(:mdt_client, __MODULE__, [])[:home] do
      nil -> []
      home -> [{"HOME", home}]
    end
  end

  defp env do
    scrubbed =
      for {name, _value} <- System.get_env(), scrubbed?(name) do
        {String.to_charlist(name), false}
      end

    for({name, value} <- home_env(), do: {String.to_charlist(name), String.to_charlist(value)}) ++
      scrubbed
  end

  defp collect(port, acc) do
    receive do
      {^port, {:data, data}} ->
        collect(port, add(acc, data))

      {^port, {:exit_status, status}} ->
        tail = last(acc.tail, @keep)
        cut = acc.bytes - byte_size(acc.head) - byte_size(tail)

        output =
          if cut > 0,
            do: text(acc.head) <> "\n[… #{cut} bytes cut …]\n" <> text(tail),
            else: text(acc.head <> tail)

        %{
          exit: status,
          output: output,
          bytes: acc.bytes,
          cut: cut,
          timed_out: false,
          error: nil
        }
    end
  end

  # The head fills up to `@keep`; the rest goes to the tail, trimmed to its
  # last `@keep` bytes whenever it holds twice that.
  defp add(acc, data) do
    room = @keep - byte_size(acc.head)
    {head, rest} = if room > 0, do: split(data, room), else: {"", data}
    tail = acc.tail <> rest
    tail = if byte_size(tail) > 2 * @keep, do: last(tail, @keep), else: tail
    %{acc | head: acc.head <> head, tail: tail, bytes: acc.bytes + byte_size(data)}
  end

  defp split(data, at) when byte_size(data) <= at, do: {data, ""}

  defp split(data, at),
    do: {binary_part(data, 0, at), binary_part(data, at, byte_size(data) - at)}

  defp last(data, size) when byte_size(data) <= size, do: data
  defp last(data, size), do: binary_part(data, byte_size(data) - size, size)

  defp text(data), do: String.replace_invalid(data, "�")
end
