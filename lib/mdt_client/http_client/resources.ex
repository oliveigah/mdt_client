defmodule MDTClient.HttpClient.Resources do
  @moduledoc """
  Owns one identity's request history.

  The table lives in this process and is written to disk only through
  `MDTClient.Vault`, so the history never touches the filesystem in the clear.
  One process runs per unlocked identity; every function takes the username it
  belongs to.
  """

  use GenServer

  require Logger

  alias MDTClient.Accounts
  alias MDTClient.HttpClient.HistoryMetadata
  alias MDTClient.Vault
  alias MDTClient.Vault.Store

  @history_file "http_history.bin"
  @end_of_table :"$end_of_table"
  @default_sync_interval :timer.seconds(30)

  @type history_id :: pos_integer()
  @type metadata :: HistoryMetadata.t()
  @type response :: Req.Response.t() | Exception.t()
  @type entry :: {history_id(), metadata(), Req.Request.t(), response()}

  @doc "Starts the history owner for one unlocked identity."
  def start_link(opts) do
    username = Keyword.fetch!(opts, :username)
    GenServer.start_link(__MODULE__, opts, name: Store.via(__MODULE__, username))
  end

  @doc "The ETS table holding this identity's history."
  @spec table(String.t()) :: :ets.tid()
  def table(username), do: handles(username).table

  @doc "The atomic counter allocating this identity's history IDs."
  @spec counter(String.t()) :: :atomics.atomics_ref()
  def counter(username), do: handles(username).counter

  @doc "Stores a completed request and returns its durable unique identifier."
  @spec record(String.t(), metadata(), Req.Request.t(), response()) :: history_id()
  def record(username, %HistoryMetadata{} = metadata, %Req.Request{} = request, response) do
    %{table: table, counter: counter} = handles(username)

    identifier = :atomics.add_get(counter, 1, 1)
    metadata = HistoryMetadata.with_search_text(metadata, request, response)
    true = :ets.insert(table, {identifier, metadata, request, response})
    identifier
  end

  @doc "Returns all recorded request history entries, newest first."
  @spec all(String.t()) :: [entry()]
  def all(username) do
    table = table(username)
    collect_entries(table, :ets.last(table))
  end

  @doc "Returns history entries whose prebuilt search text contains the given term."
  @spec search(String.t(), String.t()) :: [entry()]
  def search(username, term) when is_binary(term) do
    case HistoryMetadata.normalize_search_text(term) do
      "" ->
        all(username)

      term ->
        table = table(username)
        collect_matching_entries(table, :ets.last(table), term, [])
    end
  end

  @doc "Returns one recorded request history entry, if it exists."
  @spec get(String.t(), history_id()) :: {:ok, entry()} | :error
  def get(username, identifier) do
    case :ets.lookup(table(username), identifier) do
      [entry] -> {:ok, entry}
      [] -> :error
    end
  end

  @doc "Deletes one recorded request history entry."
  @spec delete(String.t(), history_id()) :: :ok | :error
  def delete(username, identifier) do
    GenServer.call(Store.via(__MODULE__, username), {:delete, identifier})
  end

  @doc "Clears this identity's request history."
  @spec clear(String.t()) :: :ok
  def clear(username) do
    GenServer.call(Store.via(__MODULE__, username), :clear)
  end

  @impl true
  def init(opts) do
    # So that `terminate/2` gets to flush on logout and on app shutdown.
    Process.flag(:trap_exit, true)

    username = Keyword.fetch!(opts, :username)
    key = Keyword.fetch!(opts, :key)
    path = Accounts.store_path(username, @history_file)
    :ok = File.mkdir_p(Path.dirname(path))

    table = :ets.new(:http_history, [:public, :ordered_set, read_concurrency: true])
    restore(table, path, key)

    counter = :atomics.new(1, signed: false)
    :ok = :atomics.put(counter, 1, latest_identifier(table))

    :ok = Store.publish(__MODULE__, username, %{table: table, counter: counter})
    schedule_sync()

    {:ok, %{username: username, key: key, path: path, table: table}}
  end

  @impl true
  def handle_call({:delete, identifier}, _from, state) do
    case :ets.lookup(state.table, identifier) do
      [_entry] ->
        true = :ets.delete(state.table, identifier)
        :ok = persist(state)
        {:reply, :ok, state}

      [] ->
        {:reply, :error, state}
    end
  end

  @impl true
  def handle_call(:clear, _from, state) do
    true = :ets.delete_all_objects(state.table)
    :ok = :atomics.put(counter(state.username), 1, 0)
    :ok = persist(state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:sync_history, state) do
    :ok = persist(state)
    schedule_sync()
    {:noreply, state}
  end

  # Unregister before flushing so nothing can grab a handle to a table that is
  # about to be destroyed.
  @impl true
  def terminate(_reason, state) do
    Store.release(__MODULE__, state.username)
    persist(state)
  end

  defp handles(username) do
    case Store.fetch(__MODULE__, username) do
      {:ok, handles} ->
        handles

      :error ->
        raise "the vault for #{inspect(username)} is locked; sign in before reading its history"
    end
  end

  defp persist(state) do
    File.write(state.path, Vault.seal(state.key, :ets.tab2list(state.table)))
  end

  # A file that will not decrypt is kept, not overwritten: the key was already
  # proven by the verifier, so this is corruption rather than a wrong password.
  defp restore(table, path, key) do
    case File.read(path) do
      {:ok, blob} ->
        case Vault.open(key, blob) do
          {:ok, entries} when is_list(entries) ->
            true = :ets.insert(table, entries)
            :ok

          _unreadable ->
            quarantine(path)
        end

      {:error, _reason} ->
        :ok
    end
  end

  defp quarantine(path) do
    corrupt = path <> ".corrupt"
    Logger.warning("history at #{path} could not be decrypted; moved to #{corrupt}")
    File.rename(path, corrupt)
    :ok
  end

  defp sync_interval do
    Application.get_env(:mdt_client, :http_client_history_sync_interval, @default_sync_interval)
  end

  defp schedule_sync, do: Process.send_after(self(), :sync_history, sync_interval())

  defp latest_identifier(table) do
    case :ets.last(table) do
      @end_of_table -> 0
      identifier -> identifier
    end
  end

  defp collect_entries(_table, @end_of_table), do: []

  defp collect_entries(table, identifier) do
    [entry] = :ets.lookup(table, identifier)
    [entry | collect_entries(table, :ets.prev(table, identifier))]
  end

  defp collect_matching_entries(_table, @end_of_table, _term, entries), do: Enum.reverse(entries)

  defp collect_matching_entries(table, identifier, term, entries) do
    [{_, metadata, _, _} = entry] = :ets.lookup(table, identifier)

    entries =
      if String.contains?(metadata.search_text, term), do: [entry | entries], else: entries

    collect_matching_entries(table, :ets.prev(table, identifier), term, entries)
  end
end
