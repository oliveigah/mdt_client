defmodule MDTClient.Sandbox.Egress do
  @moduledoc """
  The proxy every byte the VM sends goes through.

  The VM is created with `--proxy http://127.0.0.1:<port>`, so microsandbox
  opens an HTTP CONNECT here for each TCP connection the VM makes; the VM
  cannot opt out the way it could ignore `HTTPS_PROXY`. When this is not
  listening, the VM has no internet.

  One listener per unlocked identity, on the port its settings name. Each
  connection runs in its own process under
  `MDTClient.Sandbox.TaskSupervisor`; see `MDTClient.Sandbox.Egress.Connection`.
  A port it cannot bind is reported to the sandbox and retried, rather than
  failing the unlock.
  """

  use GenServer

  require Logger

  alias MDTClient.Sandbox.Egress.Connection
  alias MDTClient.Sandbox.Server
  alias MDTClient.Vault.Store

  @retry_after 5_000

  @doc "Starts the proxy of one unlocked identity."
  def start_link(opts) do
    username = Keyword.fetch!(opts, :username)
    GenServer.start_link(__MODULE__, username, name: Store.via(__MODULE__, username))
  end

  @doc false
  def child_spec(opts) do
    %{id: {__MODULE__, Keyword.fetch!(opts, :username)}, start: {__MODULE__, :start_link, [opts]}}
  end

  @doc "Listens again, on the port the settings name now."
  def rebind(username) do
    case Store.whereis(__MODULE__, username) do
      nil -> :ok
      pid -> GenServer.cast(pid, :rebind)
    end
  end

  @doc "Asks the proxy to tell the sandbox again whether it is listening."
  def report_again(username) do
    case Store.whereis(__MODULE__, username) do
      nil -> :ok
      pid -> GenServer.cast(pid, :report)
    end
  end

  @impl true
  def init(username) do
    Process.flag(:trap_exit, true)
    send(self(), :listen)
    {:ok, %{username: username, socket: nil, acceptor: nil, port: nil}}
  end

  # A retry scheduled before a rebind succeeded finds the socket open: it
  # would only fail on its own port and report the proxy down.
  @impl true
  def handle_info(:listen, %{socket: socket} = state) when socket != nil,
    do: {:noreply, state}

  def handle_info(:listen, state) do
    port = Server.call(state.username, :proxy_port)

    case :gen_tcp.listen(port, [
           :binary,
           ip: {127, 0, 0, 1},
           active: false,
           reuseaddr: true,
           backlog: 512,
           nodelay: true
         ]) do
      {:ok, socket} ->
        username = state.username
        options = Application.get_env(:mdt_client, __MODULE__, [])
        acceptor = spawn_link(fn -> accept(socket, username, options) end)
        {:ok, bound} = :inet.port(socket)
        report(state.username, %{listening?: true, error: nil, port: bound})
        {:noreply, %{state | socket: socket, acceptor: acceptor, port: port}}

      {:error, reason} ->
        report(state.username, %{
          listening?: false,
          error: "Could not listen on 127.0.0.1:#{port}: #{:inet.format_error(reason)}",
          port: port
        })

        Process.send_after(self(), :listen, @retry_after)
        {:noreply, state}
    end
  end

  def handle_info({:EXIT, pid, _reason}, %{acceptor: pid} = state) do
    {:noreply, state |> close() |> tap(fn _ -> send(self(), :listen) end)}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  @impl true
  def handle_cast(:report, %{socket: nil} = state), do: {:noreply, state}

  def handle_cast(:report, state) do
    {:ok, bound} = :inet.port(state.socket)
    report(state.username, %{listening?: true, error: nil, port: bound})
    {:noreply, state}
  end

  def handle_cast(:rebind, state) do
    state = close(state)
    send(self(), :listen)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    close(state)
    :ok
  end

  defp close(state) do
    if state.acceptor, do: Process.unlink(state.acceptor) && Process.exit(state.acceptor, :kill)
    if state.socket, do: :gen_tcp.close(state.socket)
    %{state | socket: nil, acceptor: nil}
  end

  defp report(username, status) do
    Server.cast(username, {:proxy, status})
  end

  defp accept(socket, username, options) do
    case :gen_tcp.accept(socket) do
      {:ok, client} ->
        case Task.Supervisor.start_child(MDTClient.Sandbox.TaskSupervisor, fn ->
               receive do
                 {:go, client} -> Connection.run(client, username, options)
               after
                 5_000 -> :ok
               end
             end) do
          {:ok, pid} ->
            :ok = :gen_tcp.controlling_process(client, pid)
            send(pid, {:go, client})

          {:error, reason} ->
            Logger.warning("sandbox proxy could not start a handler: #{inspect(reason)}",
              system: :sandbox
            )

            :gen_tcp.close(client)
        end

        accept(socket, username, options)

      {:error, :closed} ->
        exit(:normal)

      {:error, reason} ->
        exit(reason)
    end
  end
end
