defmodule MDTClient.Sandbox.Ports do
  @moduledoc """
  Which of the VM's ports show up on your machine, and where.

  Each identity's VM has a fixed address here, `127.77.X.Y` (`address/1`).
  Linux sends all of `127.0.0.0/8` to loopback, so it needs no setup, and a
  port keeps its number there without colliding with this machine's own.

  `parse/1` reads what listens in the VM (`ss -ltnpH`, run there), and
  `plan/2` decides what to forward: every TCP port, to the same port on the
  address, connecting inside the VM to loopback when the server listens
  there or on every address. Ports below the host's unprivileged start
  (1024 by default) are left out, since listening on one here needs root,
  and so is anything past `max_ports/0`.

  `MDTClient.Sandbox.Forwarder` keeps the forwards in step; this module only
  decides.
  """

  @max_ports 64
  @unprivileged_file "/proc/sys/net/ipv4/ip_unprivileged_port_start"

  @type listener :: %{port: 1..65_535, binds: [String.t()], process: String.t() | nil}

  @type entry :: %{
          port: 1..65_535,
          process: String.t() | nil,
          target: String.t(),
          status: :forwarded | :pending | {:skipped, String.t()}
        }

  @doc "How many ports are forwarded at most."
  @spec max_ports() :: pos_integer()
  def max_ports, do: @max_ports

  @doc """
  The VM's address on this machine, derived from the identity's id: the
  same on every start, and different for each identity's VM.
  """
  @spec address(String.t()) :: String.t()
  def address(identity_id) do
    <<x, y, _rest::binary>> = :crypto.hash(:sha256, "mdt-sandbox-address:" <> identity_id)
    "127.77.#{x}.#{rem(y, 254) + 1}"
  end

  @doc "`http://ADDRESS:PORT`."
  @spec url(String.t(), 1..65_535) :: String.t()
  def url(address, port), do: "http://#{address}:#{port}"

  @doc """
  The lowest port this machine lets anyone listen on without root, from
  `#{@unprivileged_file}` (1024 when it can't be read).
  """
  @spec unprivileged_start() :: non_neg_integer()
  def unprivileged_start do
    with {:ok, text} <- File.read(@unprivileged_file),
         {start, _} <- Integer.parse(String.trim(text)) do
      start
    else
      _ -> 1024
    end
  end

  @doc """
  The TCP listeners in `ss -ltnpH` output, one per port, sorted by port,
  with every address the port listens on and the first process holding it.
  """
  @spec parse(String.t()) :: [listener()]
  def parse(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.flat_map(&parse_line/1)
    |> Enum.group_by(& &1.port)
    |> Enum.map(fn {port, found} ->
      %{
        port: port,
        binds: found |> Enum.map(& &1.bind) |> Enum.uniq(),
        process: Enum.find_value(found, & &1.process)
      }
    end)
    |> Enum.sort_by(& &1.port)
  end

  defp parse_line(line) do
    with ["LISTEN", _recv, _send, local | rest] <- String.split(line),
         {bind, port} <- split_address(local) do
      [%{port: port, bind: bind, process: process(Enum.join(rest, " "))}]
    else
      _ -> []
    end
  end

  # `127.0.0.1:4000`, `[::1]:4000`, `*:4000`, `127.0.0.53%lo:53`.
  defp split_address(local) do
    with [port_text, host] <- local |> String.reverse() |> String.split(":", parts: 2),
         {port, ""} when port in 1..65_535 <- port_text |> String.reverse() |> Integer.parse() do
      host =
        host
        |> String.reverse()
        |> String.trim_leading("[")
        |> String.trim_trailing("]")
        |> String.replace(~r/%.*$/, "")
        |> String.replace_prefix("::ffff:", "")

      {host, port}
    else
      _ -> nil
    end
  end

  defp process(text) do
    case Regex.run(~r/users:\(\("([^"]+)"/, text) do
      [_, name] -> name
      nil -> nil
    end
  end

  @doc """
  What to do with each listener: forward it to `target` inside the VM, or
  skip it, with why. `:unprivileged_start` defaults to this machine's.
  """
  @spec plan([listener()], keyword()) :: [entry()]
  def plan(listeners, opts \\ []) do
    start = Keyword.get_lazy(opts, :unprivileged_start, &unprivileged_start/0)
    max = Keyword.get(opts, :max_ports, @max_ports)

    {entries, _count} =
      Enum.map_reduce(listeners, 0, fn listener, count ->
        entry = %{port: listener.port, process: listener.process, target: target(listener.binds)}

        cond do
          listener.port < start ->
            {Map.put(
               entry,
               :status,
               {:skipped, "Below #{start}: listening on it here needs root"}
             ), count}

          count >= max ->
            {Map.put(entry, :status, {:skipped, "Past #{max} ports"}), count}

          true ->
            {Map.put(entry, :status, :pending), count + 1}
        end
      end)

    entries
  end

  # Loopback when the server listens there or everywhere (`*` is IPv6 with
  # IPv4 too); `::1` for a server only on IPv6; otherwise the one address it
  # listens on, such as another of the VM's loopback addresses.
  defp target(binds) do
    cond do
      Enum.any?(binds, &(&1 in ["0.0.0.0", "*", "127.0.0.1"])) ->
        "127.0.0.1"

      Enum.any?(binds, &(&1 in ["::", "::1"])) ->
        "::1"

      true ->
        hd(binds)
    end
  end
end
