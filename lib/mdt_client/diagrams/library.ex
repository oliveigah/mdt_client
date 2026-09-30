defmodule MDTClient.Diagrams.Library do
  @moduledoc """
  Owns one identity's diagrams.

  They live in this process and reach disk only through `MDTClient.Vault`, so
  a diagram never touches the filesystem in the clear. One process runs per
  unlocked identity, started by `MDTClient.Vault.Store`; every function takes
  the username it belongs to.

  Diagrams are small and edited by one person at a time, so everything goes
  through this process rather than a shared table. Lists come back as
  summaries, built here, so searching as someone types copies titles and
  snippets rather than every element of every diagram.
  """

  use GenServer

  require Logger

  alias MDTClient.Accounts
  alias MDTClient.Diagrams.Diagram
  alias MDTClient.Vault
  alias MDTClient.Vault.Store

  @library_file "diagrams.bin"
  @flush_after 250

  @type summary :: %{
          id: String.t(),
          title: String.t(),
          updated_at: DateTime.t(),
          count: non_neg_integer(),
          snippet: {String.t(), String.t(), String.t()} | nil
        }

  @doc "Starts the library for one unlocked identity."
  def start_link(opts) do
    username = Keyword.fetch!(opts, :username)
    GenServer.start_link(__MODULE__, opts, name: Store.via(__MODULE__, username))
  end

  @doc """
  Summaries of the diagrams holding every word of `term`, the most recently
  changed first. A blank term lists them all.
  """
  @spec list(String.t(), String.t()) :: [summary()]
  def list(username, term \\ "") when is_binary(term) do
    call(username, {:list, Diagram.terms(term)})
  end

  @doc "The diagram changed last, if there is one."
  @spec latest(String.t()) :: {:ok, Diagram.t()} | :error
  def latest(username), do: call(username, :latest)

  @doc "One diagram, elements and all."
  @spec get(String.t(), String.t()) :: {:ok, Diagram.t()} | :error
  def get(username, id), do: call(username, {:get, id})

  @doc "Every diagram, the oldest change first."
  @spec all(String.t()) :: [Diagram.t()]
  def all(username), do: call(username, :all)

  @doc """
  Writes `:title` and `:elements` into the diagram `id`, creating it if it is
  not there yet.

  A diagram exists from its first save, so one opened and left empty does not
  clutter the list.
  """
  @spec save(String.t(), String.t(), map()) :: {:ok, Diagram.t()} | {:error, :invalid_id}
  def save(username, id, attrs) when is_map(attrs) do
    if Diagram.id?(id), do: call(username, {:save, id, attrs}), else: {:error, :invalid_id}
  end

  @doc "Copies a diagram under a new identifier and title."
  @spec duplicate(String.t(), String.t()) :: {:ok, Diagram.t()} | :error
  def duplicate(username, id), do: call(username, {:duplicate, id})

  @doc "Deletes one diagram."
  @spec delete(String.t(), String.t()) :: :ok | :error
  def delete(username, id), do: call(username, {:delete, id})

  @doc """
  Replaces every diagram with what `fun` returns when given them all, oldest
  change first. It runs in this process, so no save can land in between.
  """
  @spec rewrite(String.t(), ([Diagram.t()] -> [Diagram.t()])) :: :ok
  def rewrite(username, fun) when is_function(fun, 1) do
    GenServer.call(Store.via(__MODULE__, username), {:rewrite, fun}, :infinity)
  end

  defp call(username, request), do: GenServer.call(Store.via(__MODULE__, username), request)

  @impl true
  def init(opts) do
    # So that `terminate/2` gets to write on logout and on app shutdown.
    Process.flag(:trap_exit, true)

    username = Keyword.fetch!(opts, :username)
    key = Keyword.fetch!(opts, :key)
    path = Accounts.store_path(username, @library_file)
    :ok = File.mkdir_p(Path.dirname(path))

    {:ok,
     %{
       username: username,
       key: key,
       path: path,
       diagrams: restore(path, key, username),
       flush: nil
     }}
  end

  @impl true
  def handle_call({:list, terms}, _from, state) do
    summaries =
      for diagram <- newest_first(state.diagrams), Diagram.matches?(diagram, terms) do
        %{
          id: diagram.id,
          title: diagram.title,
          updated_at: diagram.updated_at,
          count: length(diagram.elements),
          snippet: Diagram.snippet(diagram, terms)
        }
      end

    {:reply, summaries, state}
  end

  def handle_call(:latest, _from, state) do
    case newest_first(state.diagrams) do
      [diagram | _rest] -> {:reply, {:ok, diagram}, state}
      [] -> {:reply, :error, state}
    end
  end

  def handle_call({:get, id}, _from, state) do
    {:reply, Map.fetch(state.diagrams, id), state}
  end

  def handle_call(:all, _from, state) do
    {:reply, state.diagrams |> newest_first() |> Enum.reverse(), state}
  end

  def handle_call({:save, id, attrs}, _from, state) do
    attrs = Map.take(attrs, [:title, :elements])

    case Map.fetch(state.diagrams, id) do
      {:ok, diagram} ->
        case Diagram.update(diagram, attrs) do
          ^diagram -> {:reply, {:ok, diagram}, state}
          updated -> {:reply, {:ok, updated}, state |> put(updated) |> changed()}
        end

      :error ->
        diagram = Diagram.new(Map.put(attrs, :id, id))
        {:reply, {:ok, diagram}, state |> put(diagram) |> changed()}
    end
  end

  def handle_call({:duplicate, id}, _from, state) do
    case Map.fetch(state.diagrams, id) do
      {:ok, diagram} ->
        copy = Diagram.new(%{title: "#{diagram.title} copy", elements: diagram.elements})
        {:reply, {:ok, copy}, state |> put(copy) |> changed()}

      :error ->
        {:reply, :error, state}
    end
  end

  def handle_call({:delete, id}, _from, state) do
    if Map.has_key?(state.diagrams, id) do
      {:reply, :ok, flushed(%{state | diagrams: Map.delete(state.diagrams, id)})}
    else
      {:reply, :error, state}
    end
  end

  def handle_call({:rewrite, fun}, _from, state) do
    diagrams =
      state.diagrams
      |> newest_first()
      |> Enum.reverse()
      |> fun.()
      |> Map.new(&{&1.id, &1})

    {:reply, :ok, flushed(%{state | diagrams: diagrams})}
  end

  @impl true
  def handle_info(:flush, state) do
    :ok = persist(state)
    {:noreply, %{state | flush: nil}}
  end

  @impl true
  def terminate(_reason, state) do
    persist(state)
    :ok
  end

  defp put(state, diagram), do: %{state | diagrams: Map.put(state.diagrams, diagram.id, diagram)}

  # Coalesced rather than written straight away: dragging a shape around saves
  # on every drop, and that becomes one write, while nothing waits longer than
  # @flush_after to become durable.
  defp changed(%{flush: nil} = state) do
    %{state | flush: Process.send_after(self(), :flush, @flush_after)}
  end

  defp changed(state), do: state

  # Writes now and drops any pending timer, so a later :flush cannot fire
  # against state that has already been written.
  defp flushed(state) do
    if state.flush, do: Process.cancel_timer(state.flush)
    :ok = persist(state)
    %{state | flush: nil}
  end

  defp newest_first(diagrams) do
    diagrams |> Map.values() |> Enum.sort_by(& &1.updated_at, {:desc, DateTime})
  end

  # Written aside and renamed into place, so a crash partway through a write
  # leaves the previous file rather than half of a new one.
  defp persist(state) do
    partial = "#{state.path}.part"
    blob = Vault.seal(state.key, Map.values(state.diagrams))

    with :ok <- File.write(partial, blob),
         :ok <- File.rename(partial, state.path) do
      :ok
    else
      {:error, reason} ->
        Logger.error(
          "could not write diagrams to #{state.path}: #{:file.format_error(reason)}",
          user: state.username,
          system: :diagrams
        )

        :ok
    end
  end

  # A file that will not decrypt is kept, not overwritten: the key was already
  # proven by the verifier, so this is corruption rather than a wrong password.
  defp restore(path, key, username) do
    case File.read(path) do
      {:ok, blob} ->
        case Vault.open(key, blob) do
          {:ok, diagrams} when is_list(diagrams) ->
            Map.new(diagrams, &{&1.id, &1})

          _unreadable ->
            quarantine(path, username)
            %{}
        end

      {:error, _reason} ->
        %{}
    end
  end

  # Timestamped so a second failed start cannot overwrite the copy kept by the
  # first, which would turn a recoverable problem into data loss.
  defp quarantine(path, username) do
    corrupt = "#{path}.#{System.system_time(:second)}.corrupt"

    Logger.warning("diagrams at #{path} could not be decrypted; kept as #{corrupt}",
      user: username,
      system: :diagrams
    )

    File.rename(path, corrupt)
  end
end
