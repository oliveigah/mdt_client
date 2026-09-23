defmodule MDTClient.HttpClient.Requests do
  @moduledoc """
  Runs HTTP requests outside LiveView processes.

  One executor exists per unlocked identity. Requests therefore keep running
  while the user changes tools or reconnects, but are cancelled when the vault
  is locked. PubSub messages contain only response metadata and a history ID;
  response bodies stay out of LiveView mailboxes until the UI asks for one.
  """

  use GenServer

  alias MDTClient.Accounts
  alias MDTClient.HttpClient.Core
  alias MDTClient.HttpClient.Translation
  alias MDTClient.Vault.Store

  @task_supervisor MDTClient.HttpClient.TaskSupervisor

  @type request_id :: String.t()
  @type completion :: %{history_id: pos_integer(), response: map()}

  def start_link(opts) do
    username = Keyword.fetch!(opts, :username)
    GenServer.start_link(__MODULE__, opts, name: Store.via(__MODULE__, username))
  end

  @doc "Subscribes the caller to compact request lifecycle events for an identity."
  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(username), do: Phoenix.PubSub.subscribe(MDTClient.PubSub, topic(username))

  @doc "Starts a request unless the supplied request ID is already running."
  @spec start(String.t(), request_id(), Req.Request.t(), map()) ::
          :ok | {:error, :already_running}
  def start(username, request_id, %Req.Request{} = request, metadata)
      when is_binary(request_id) do
    GenServer.call(Store.via(__MODULE__, username), {:start, request_id, request, metadata})
  end

  @doc "Cancels one request without affecting requests in other tabs."
  @spec cancel(String.t(), request_id()) :: :ok
  def cancel(username, request_id) do
    GenServer.call(Store.via(__MODULE__, username), {:cancel, request_id})
  end

  @doc "Lists request IDs that are still running for an identity."
  @spec running(String.t()) :: [request_id()]
  def running(username) do
    GenServer.call(Store.via(__MODULE__, username), :running)
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    {:ok, %{username: Keyword.fetch!(opts, :username), requests: %{}, refs: %{}}}
  end

  @impl true
  def handle_call({:start, request_id, request, metadata}, _from, state) do
    if Map.has_key?(state.requests, request_id) do
      {:reply, {:error, :already_running}, state}
    else
      username = state.username

      task =
        Task.Supervisor.async_nolink(@task_supervisor, fn ->
          {result, history_id, duration_ms} = Core.request_recorded(username, request, metadata)

          %{
            history_id: history_id,
            response: Translation.response_summary(result, duration_ms)
          }
        end)

      state = %{
        state
        | requests: Map.put(state.requests, request_id, task),
          refs: Map.put(state.refs, task.ref, request_id)
      }

      {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:cancel, request_id}, _from, state) do
    case Map.pop(state.requests, request_id) do
      {nil, _requests} ->
        {:reply, :ok, state}

      {%Task{} = task, requests} ->
        Process.demonitor(task.ref, [:flush])
        terminate_task(task.pid)
        broadcast(state.username, {:http_request_cancelled, request_id})

        {:reply, :ok, %{state | requests: requests, refs: Map.delete(state.refs, task.ref)}}
    end
  end

  @impl true
  def handle_call(:running, _from, state) do
    {:reply, Map.keys(state.requests), state}
  end

  @impl true
  def handle_info({ref, completion}, state) when is_reference(ref) do
    case Map.pop(state.refs, ref) do
      {nil, _refs} ->
        {:noreply, state}

      {request_id, refs} ->
        Process.demonitor(ref, [:flush])
        broadcast(state.username, {:http_request_finished, request_id, completion})

        {:noreply, %{state | refs: refs, requests: Map.delete(state.requests, request_id)}}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.refs, ref) do
      {nil, _refs} ->
        {:noreply, state}

      {request_id, refs} ->
        broadcast(state.username, {:http_request_failed, request_id, inspect(reason)})

        {:noreply, %{state | refs: refs, requests: Map.delete(state.requests, request_id)}}
    end
  end

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.requests, fn {_request_id, task} ->
      Process.demonitor(task.ref, [:flush])
      terminate_task(task.pid)
    end)

    :ok
  end

  defp broadcast(username, message) do
    Phoenix.PubSub.broadcast(MDTClient.PubSub, topic(username), message)
  end

  defp terminate_task(pid) do
    case Task.Supervisor.terminate_child(@task_supervisor, pid) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end
  end

  defp topic(username), do: "http-requests:" <> Accounts.id(username)
end
