defmodule MDTClient.HttpClient.Resources do
  @moduledoc """
  Owns the durable HTTP request history.
  """

  use GenServer

  alias MDTClient.HttpClient.HistoryMetadata

  @table __MODULE__
  @end_of_table :"$end_of_table"
  @default_sync_interval :timer.seconds(30)

  @type history_id :: pos_integer()
  @type metadata :: HistoryMetadata.t()
  @type response :: Req.Response.t() | Exception.t()
  @type entry :: {history_id(), metadata(), Req.Request.t(), response()}

  @doc "Starts the process that owns the request history table."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))
  end

  @doc "Returns the named ETS table that stores request history."
  @spec table() :: atom()
  def table, do: @table

  @doc "Returns the atomic counter used to allocate request history IDs."
  @spec counter() :: :atomics.atomics_ref()
  def counter, do: :persistent_term.get({__MODULE__, :counter})

  @doc "Stores a completed request and returns its durable unique identifier."
  @spec record(metadata(), Req.Request.t(), response()) :: history_id()
  def record(%HistoryMetadata{} = metadata, %Req.Request{} = request, response) do
    identifier = :atomics.add_get(counter(), 1, 1)
    metadata = HistoryMetadata.with_search_text(metadata, request, response)
    true = :ets.insert(@table, {identifier, metadata, request, response})
    identifier
  end

  @doc "Returns all recorded request history entries, newest first."
  @spec all() :: [entry()]
  def all, do: entries_newest_first()

  @doc "Returns history entries whose prebuilt search text contains the given term."
  @spec search(String.t()) :: [entry()]
  def search(term) when is_binary(term) do
    case HistoryMetadata.normalize_search_text(term) do
      "" -> all()
      term -> collect_matching_entries(:ets.last(@table), term)
    end
  end

  @doc "Returns one recorded request history entry, if it exists."
  @spec get(history_id()) :: {:ok, entry()} | :error
  def get(identifier) do
    case :ets.lookup(@table, identifier) do
      [entry] -> {:ok, entry}
      [] -> :error
    end
  end

  @doc "Deletes one recorded request history entry."
  @spec delete(history_id()) :: :ok | :error
  def delete(identifier) do
    case :ets.lookup(@table, identifier) do
      [_entry] ->
        true = :ets.delete(@table, identifier)
        persist_history(history_path())

      [] ->
        :error
    end
  end

  @doc "Clears the in-memory and persisted request history."
  @spec clear() :: :ok
  def clear do
    true = :ets.delete_all_objects(@table)
    :ok = :atomics.put(counter(), 1, 0)
    :ok = persist_history(history_path())
  end

  @impl true
  def init(:ok) do
    path = history_path()
    :ok = File.mkdir_p(Path.dirname(path))
    restore_history(path)

    counter = :atomics.new(1, signed: false)
    :ok = :atomics.put(counter, 1, latest_identifier())
    :persistent_term.put({__MODULE__, :counter}, counter)

    schedule_sync()
    {:ok, %{path: path}}
  end

  @impl true
  def handle_info(:sync_history, state) do
    :ok = persist_history(state.path)
    schedule_sync()
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state), do: persist_history(state.path)

  defp history_path do
    Application.get_env(
      :mdt_client,
      :http_client_history_path,
      Path.join([System.user_home!(), ".mdt_client", "http_client_history.ets"])
    )
  end

  defp sync_interval do
    Application.get_env(:mdt_client, :http_client_history_sync_interval, @default_sync_interval)
  end

  defp restore_history(path) do
    if File.exists?(path) do
      {:ok, @table} = :ets.file2tab(String.to_charlist(path), verify: true)
    else
      :ets.new(@table, [:named_table, :public, :ordered_set, read_concurrency: true])
    end

    true = :ets.setopts(@table, protection: :public)
  end

  defp persist_history(path) do
    :ets.tab2file(@table, String.to_charlist(path), sync: true)
  end

  defp schedule_sync, do: Process.send_after(self(), :sync_history, sync_interval())

  defp latest_identifier do
    case :ets.last(@table) do
      @end_of_table -> 0
      identifier -> identifier
    end
  end

  defp entries_newest_first, do: collect_entries(:ets.last(@table))
  defp collect_entries(@end_of_table), do: []

  defp collect_entries(identifier) do
    [entry] = :ets.lookup(@table, identifier)
    [entry | collect_entries(:ets.prev(@table, identifier))]
  end

  defp collect_matching_entries(@end_of_table, _term), do: []

  defp collect_matching_entries(identifier, term),
    do: collect_matching_entries(identifier, term, [])

  defp collect_matching_entries(@end_of_table, _term, entries), do: Enum.reverse(entries)

  defp collect_matching_entries(identifier, term, entries) do
    [{_, metadata, _, _} = entry] = :ets.lookup(@table, identifier)

    entries =
      if String.contains?(metadata.search_text, term), do: [entry | entries], else: entries

    collect_matching_entries(:ets.prev(@table, identifier), term, entries)
  end
end
