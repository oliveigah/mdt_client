defmodule MDTClient.Sandbox.Forwarder do
  @moduledoc """
  Keeps a running VM's ports forwarded to its address on this machine
  (`MDTClient.Sandbox.Ports`). One per running VM, started and stopped by
  `MDTClient.Sandbox.Server`, which it tells what is forwarded with
  `{:ports, pid, %{status: status, ports: entries}}`.

  It opens a tunnel to the VM (`MDTClient.Sandbox.Forwarder.SSH`; tests use
  their own, set as `config :mdt_client, MDTClient.Sandbox.Forwarder,
  tunnel: module`). Then every 2 seconds it lists what listens in the VM,
  forwards what is new and removes what stopped listening. A port that
  couldn't be forwarded is tried again after 30 seconds; when the tunnel
  closes, it opens it again every 5 seconds.

  The status is `:connecting` until the first listing, `:on` after, and
  `{:error, message}` while the tunnel is down or can't list.
  """

  use GenServer

  alias MDTClient.Sandbox.Ports

  @doc "Opens the tunnel; its `:port` field is the port or ref whose `{:exit_status, _}` says it closed."
  @callback open(opts :: map()) :: {:ok, conn :: map()} | {:error, String.t()}

  @doc "What listens in the VM, as `ss -ltnpH` prints it."
  @callback listeners(conn :: map()) :: {:ok, String.t()} | {:error, String.t()}

  @doc "Starts listening on `address:port` here, connecting to `target:port` in the VM."
  @callback forward(conn :: map(), address :: String.t(), 1..65_535, target :: String.t()) ::
              :ok | {:error, String.t()}

  @doc "Stops a forward."
  @callback cancel(conn :: map(), address :: String.t(), 1..65_535, target :: String.t()) :: :ok

  @doc "Closes the tunnel and its forwards."
  @callback close(conn :: map()) :: :ok

  @defaults %{poll_every: 2_000, reconnect_every: 5_000, retry_after: 30_000}
  # The tunnel's first listings can come before it is up.
  @connect_grace 10

  @doc """
  Starts forwarding. Options: `:report_to`, `:address`, `:tunnel` (the
  module), `:tunnel_opts` (given to its `open/1`), and for tests
  `:unprivileged_start`, `:poll_every`, `:reconnect_every`, `:retry_after`.
  """
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    state =
      Map.merge(@defaults, Map.new(Keyword.take(opts, Map.keys(@defaults))))
      |> Map.merge(%{
        report_to: Keyword.fetch!(opts, :report_to),
        address: Keyword.fetch!(opts, :address),
        tunnel: Keyword.fetch!(opts, :tunnel),
        tunnel_opts: Keyword.get(opts, :tunnel_opts, %{}),
        unprivileged_start:
          Keyword.get_lazy(opts, :unprivileged_start, &Ports.unprivileged_start/0),
        conn: nil,
        said: "",
        status: :connecting,
        misses: 0,
        forwarded: %{},
        failed: %{},
        entries: [],
        reported: nil
      })

    send(self(), :connect)
    {:ok, state}
  end

  @impl true
  def handle_info(:connect, state) do
    case state.tunnel.open(state.tunnel_opts) do
      {:ok, conn} ->
        send(self(), :poll)
        {:noreply, report(%{state | conn: conn, said: "", status: :connecting, misses: 0})}

      {:error, message} ->
        Process.send_after(self(), :connect, state.reconnect_every)
        {:noreply, report(%{state | status: {:error, message}})}
    end
  end

  def handle_info(:poll, %{conn: nil} = state), do: {:noreply, state}

  def handle_info(:poll, state) do
    Process.send_after(self(), :poll, state.poll_every)

    case state.tunnel.listeners(state.conn) do
      {:ok, output} ->
        entries =
          output
          |> Ports.parse()
          |> Ports.plan(unprivileged_start: state.unprivileged_start)

        {:noreply, state |> Map.merge(%{status: :on, misses: 0}) |> sync(entries) |> report()}

      {:error, message} ->
        misses = state.misses + 1

        status =
          if state.status == :connecting and misses < @connect_grace,
            do: :connecting,
            else: {:error, "Couldn't list the VM's ports: " <> message}

        {:noreply, report(%{state | misses: misses, status: status})}
    end
  end

  # What the tunnel prints, kept for when it closes.
  def handle_info({port, {:data, data}}, %{conn: %{port: port}} = state),
    do: {:noreply, %{state | said: String.slice(state.said <> data, -500, 500)}}

  def handle_info({port, {:exit_status, status}}, %{conn: %{port: port}} = state) do
    said = state.said |> String.trim() |> String.split("\n") |> List.last()
    detail = if said in [nil, ""], do: "exit #{status}", else: said

    Process.send_after(self(), :connect, state.reconnect_every)

    {:noreply,
     report(%{
       state
       | conn: nil,
         forwarded: %{},
         failed: %{},
         entries: [],
         status: {:error, "The connection to the VM closed (#{detail})"}
     })}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{conn: conn, tunnel: tunnel}) when not is_nil(conn),
    do: tunnel.close(conn)

  def terminate(_reason, _state), do: :ok

  # Forwards what is new or moved, removes what is gone, and retries what
  # failed once its wait is over.
  defp sync(state, entries) do
    wanted = for %{status: :pending} = entry <- entries, into: %{}, do: {entry.port, entry.target}
    now = System.monotonic_time(:millisecond)

    state =
      Enum.reduce(state.forwarded, state, fn {port, target}, acc ->
        if Map.get(wanted, port) == target do
          acc
        else
          acc.tunnel.cancel(acc.conn, acc.address, port, target)
          %{acc | forwarded: Map.delete(acc.forwarded, port)}
        end
      end)

    state = %{state | failed: Map.take(state.failed, Map.keys(wanted))}

    state =
      Enum.reduce(wanted, state, fn {port, target}, acc ->
        cond do
          Map.get(acc.forwarded, port) == target ->
            acc

          match?({^target, _reason, at} when now - at < acc.retry_after, acc.failed[port]) ->
            acc

          true ->
            case acc.tunnel.forward(acc.conn, acc.address, port, target) do
              :ok ->
                %{
                  acc
                  | forwarded: Map.put(acc.forwarded, port, target),
                    failed: Map.delete(acc.failed, port)
                }

              {:error, message} ->
                reason = why_not(acc.address, port, message)
                %{acc | failed: Map.put(acc.failed, port, {target, reason, now})}
            end
        end
      end)

    entries =
      Enum.map(entries, fn entry ->
        cond do
          entry.status != :pending -> entry
          Map.has_key?(state.forwarded, entry.port) -> %{entry | status: :forwarded}
          failed = state.failed[entry.port] -> %{entry | status: {:skipped, elem(failed, 1)}}
          true -> entry
        end
      end)

    %{state | entries: entries}
  end

  # The tunnel only says it failed; trying the port here says why.
  defp why_not(address, port, message) do
    {:ok, ip} = :inet.parse_address(String.to_charlist(address))

    case :gen_tcp.listen(port, ip: ip, reuseaddr: true) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        "Couldn't forward it: #{message}"

      {:error, :eaddrinuse} ->
        "Something on this machine already uses it"

      {:error, :eacces} ->
        "Listening on it here needs root"

      {:error, reason} ->
        "Couldn't listen on it here (#{reason})"
    end
  end

  defp report(state) do
    snapshot = %{status: state.status, ports: state.entries}

    if snapshot != state.reported do
      send(state.report_to, {:ports, self(), snapshot})
      %{state | reported: snapshot}
    else
      state
    end
  end
end
