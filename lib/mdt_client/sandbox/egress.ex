defmodule MDTClient.Sandbox.Egress do
  @moduledoc """
  The proxy every byte the VM sends goes through.

  The VM is created with `--proxy http://127.0.0.1:3128`, a port that exists
  only in the VM's bubble, where the relay joins it to this proxy's Unix
  socket (`proxy.sock`, see `MDTClient.Sandbox.Sockets`). So microsandbox
  opens an HTTP CONNECT here for each TCP connection the VM makes; the VM
  cannot opt out the way it could ignore `HTTPS_PROXY`, and the bubble has
  no network of its own to go around it. When this is not listening, the VM
  has no internet. No other program reaches it through a port.

  One listener per unlocked identity. Each connection runs in its own
  process under `MDTClient.Sandbox.TaskSupervisor`; see
  `MDTClient.Sandbox.Egress.Connection`. A socket it cannot bind is reported
  to the sandbox and retried, rather than failing the unlock.
  """

  use GenServer

  require Logger

  alias MDTClient.Sandbox.Egress.Connection
  alias MDTClient.Sandbox.Server
  alias MDTClient.Sandbox.Sockets
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

  @doc "The Unix socket one identity's proxy listens on (`MDTClient.Sandbox.Sockets`)."
  @spec path(String.t()) :: Path.t()
  def path(username), do: Sockets.path(username, "proxy.sock")

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
    {:ok, %{username: username, socket: nil, acceptor: nil}}
  end

  # A retry scheduled before a rebind succeeded finds the socket open: it
  # would only fail on its own port and report the proxy down.
  @impl true
  def handle_info(:listen, %{socket: socket} = state) when socket != nil,
    do: {:noreply, state}

  def handle_info(:listen, state) do
    Sockets.ensure!(state.username)
    path = path(state.username)
    # A socket file left by an MDT that crashed would refuse the bind.
    File.rm(path)

    case :gen_tcp.listen(0, [:binary, ifaddr: {:local, path}, active: false, backlog: 512]) do
      {:ok, socket} ->
        File.chmod(path, 0o600)
        username = state.username
        options = Application.get_env(:mdt_client, __MODULE__, [])
        acceptor = spawn_link(fn -> accept(socket, username, options) end)
        report(state.username, %{listening?: true, error: nil, path: path})
        {:noreply, %{state | socket: socket, acceptor: acceptor}}

      {:error, reason} ->
        report(state.username, %{
          listening?: false,
          error: "Could not listen on #{path}: #{:inet.format_error(reason)}",
          path: path
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
    report(state.username, %{listening?: true, error: nil, path: path(state.username)})
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    close(state)
    File.rm(path(state.username))
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
