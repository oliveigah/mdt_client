defmodule MDTClient.Sandbox.Memory do
  @moduledoc """
  The VM's own OptMem, kept in a host folder mounted at `/root/.optmem`, and
  its round trip with yours.

    * `prepare!/1` - before each start: copies your `memo` tool in, and
      creates an empty memory when there is none.
    * `seed!/1` - replaces the VM's memory with a copy of yours (`LOG.txt`,
      `TREE/`, `config`: what `memo sync` shares), taken under memo's lock.
      The VM's previous memory is moved aside, never deleted.
    * `entries/2` - what the VM noted, read as data: complete lines of
      `LOG.txt` only, so a record the VM is still writing is skipped.
    * `bring_back/1` - adds chosen entries to your memory with `memo note`.
      memo asks your next agent session for the summaries.

  The VM's `flock` doesn't reach the host, so MDT writes the VM's memory
  only while the VM is stopped, and never runs anything from that folder.
  """

  @shared ["LOG.txt", "TREE", "config"]

  @type entry :: %{index: non_neg_integer(), id: String.t(), date: String.t(), text: String.t()}

  @doc "Your `memo` tool, or nil when OptMem isn't installed here."
  @spec host_memo() :: Path.t() | nil
  def host_memo do
    path = Path.join(System.user_home!(), ".optmem/memo")
    if File.regular?(path), do: path
  end

  @doc "Your memory's folder."
  @spec host_memory() :: Path.t()
  def host_memory,
    do: System.get_env("MEMORY_DIR") || Path.join(System.user_home!(), ".optmem/memory")

  @doc "Whether you have a memory to copy from."
  @spec host_memory?() :: boolean()
  def host_memory?, do: host_memo() != nil and File.regular?(Path.join(host_memory(), "LOG.txt"))

  @doc """
  Copies `memo` into the VM's OptMem folder and creates an empty memory when
  it has none. Does nothing without OptMem on this machine.
  """
  @spec prepare!(Path.t()) :: :ok
  def prepare!(optmem) do
    File.mkdir_p!(optmem)

    with memo when is_binary(memo) <- host_memo() do
      target = Path.join(optmem, "memo")
      File.cp!(memo, target)
      File.chmod!(target, 0o755)

      memory = Path.join(optmem, "memory")

      unless File.regular?(Path.join(memory, "LOG.txt")) do
        case System.cmd(memo, ["init"], env: [{"MEMORY_DIR", memory}], stderr_to_stdout: true) do
          {_, 0} -> :ok
          {output, status} -> raise "memo init failed (#{status}): #{String.trim(output)}"
        end
      end
    end

    :ok
  end

  @doc """
  Replaces the VM's memory with a copy of yours and returns how many memories
  the copy holds: the seed point, after which the VM's own notes start.
  """
  @spec seed!(Path.t(), Path.t()) :: non_neg_integer()
  def seed!(optmem, source \\ host_memory()) do
    unless File.regular?(Path.join(source, "LOG.txt")),
      do: raise("there is no OptMem memory at #{source} to copy")

    incoming = Path.join(optmem, "memory.incoming")
    File.rm_rf!(incoming)
    File.mkdir_p!(incoming)

    parts =
      for name <- @shared, File.exists?(Path.join(source, name)), do: Path.join(source, name)

    # memo holds .lock while it reads or writes, so a copy under it never
    # catches a note half written.
    case System.cmd(
           "flock",
           [Path.join(source, ".lock"), "cp", "-a" | parts] ++ [incoming],
           stderr_to_stdout: true
         ) do
      {_, 0} -> :ok
      {output, status} -> raise "copying your memory failed (#{status}): #{String.trim(output)}"
    end

    memory = Path.join(optmem, "memory")

    if File.exists?(memory) do
      stamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%dT%H%M%S")
      File.rename!(memory, Path.join(optmem, "memory.before-#{stamp}"))
    end

    File.rename!(incoming, memory)
    count(optmem)
  end

  @doc "How many memories the VM's memory holds."
  @spec count(Path.t()) :: non_neg_integer()
  def count(optmem), do: optmem |> lines() |> length()

  @doc "The VM's memories from position `from` on (0 is the first)."
  @spec entries(Path.t(), non_neg_integer()) :: [entry()]
  def entries(optmem, from) do
    optmem
    |> lines()
    |> Enum.with_index()
    |> Enum.drop(from)
    |> Enum.map(fn {line, index} -> parse(line, index) end)
  end

  @doc """
  Adds each text to your memory with `memo note`, in order. Returns one
  result per text: `:ok`, or memo's own words when it refuses (too long,
  for one).
  """
  @spec bring_back([String.t()]) :: [:ok | {:error, String.t()}]
  def bring_back(texts) do
    case host_memo() do
      nil ->
        Enum.map(texts, fn _ -> {:error, "OptMem isn't installed on this machine."} end)

      memo ->
        Enum.map(texts, fn text ->
          case System.cmd(memo, ["note", text], stderr_to_stdout: true) do
            {_, 0} -> :ok
            {output, _} -> {:error, output |> String.trim() |> String.slice(0, 300)}
          end
        end)
    end
  end

  # Complete lines only: a record still being written has no newline yet.
  defp lines(optmem) do
    case File.read(Path.join([optmem, "memory", "LOG.txt"])) do
      {:ok, content} ->
        content
        |> String.split("\n")
        |> Enum.drop(-1)
        |> Enum.map(&String.trim_trailing/1)
        |> Enum.reject(&(&1 == ""))

      {:error, _} ->
        []
    end
  end

  defp parse(line, index) do
    case Regex.run(~r/^#(\d+) (\d{4}-\d{2}-\d{2}) (.*)$/s, line) do
      [_, id, date, text] -> %{index: index, id: id, date: date, text: text}
      nil -> %{index: index, id: "#{index}", date: "", text: line}
    end
  end
end
