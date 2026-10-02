defmodule MDTClient.HttpClient.Resources do
  @moduledoc """
  Owns one identity's request history.

  The table lives in this process and is written to disk only through
  `MDTClient.Vault`, so the history never touches the filesystem in the clear.
  One process runs per unlocked identity; every function takes the username it
  belongs to.

  Writing means sealing the whole history again, which for one with large
  responses is tens of megabytes, so it happens only after a change.
  """

  use GenServer

  require Logger

  alias MDTClient.Accounts
  alias MDTClient.HttpClient.HistoryMetadata
  alias MDTClient.HttpClient.Utils
  alias MDTClient.Search
  alias MDTClient.Vault
  alias MDTClient.Vault.Store

  @doc "Subscribes to changes made to saved requests by other processes."
  def subscribe(username), do: Phoenix.PubSub.subscribe(MDTClient.PubSub, topic(username))

  @history_file "http_history.bin"
  @end_of_table :"$end_of_table"
  @flush_after 250
  # Entries re-indexed per message, so a delete or a clear never waits on
  # the whole history.
  @reindex_batch 50

  @type history_id :: pos_integer()
  @type metadata :: HistoryMetadata.t()
  @typedoc "Nil marks a saved request sample that has never been sent."
  @type response :: Req.Response.t() | Exception.t() | nil
  @type entry :: {history_id(), metadata(), Req.Request.t(), response()}
  @typedoc "An entry without the identifier this table gave it."
  @type history_data :: {metadata(), Req.Request.t(), response()}
  @type outline ::
          {history_id(), metadata(), Req.Request.t(),
           {:response, non_neg_integer(), map(), non_neg_integer()}
           | {:error, Exception.t()}
           | :sample}
  @type summary ::
          {history_id(), String.t() | nil, [String.t()], DateTime.t(), non_neg_integer(), atom(),
           URI.t(), non_neg_integer()}

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

  @doc "Stores a completed request or an unsent sample and returns its unique identifier."
  @spec record(String.t(), metadata(), Req.Request.t(), response()) :: history_id()
  def record(username, %HistoryMetadata{} = metadata, %Req.Request{} = request, response) do
    %{table: table, outlines: outlines, counter: counter} = handles(username)

    identifier = :atomics.add_get(counter, 1, 1)
    metadata = HistoryMetadata.with_search_text(metadata, request, response)
    true = :ets.insert(table, {identifier, metadata, request, response})
    true = :ets.insert(outlines, {identifier, response_outline(response)})
    :ok = touch(username)
    identifier
  end

  @doc """
  Marks the history as changed so it reaches disk shortly.

  Callers that write to the table directly must call this. Without it a change
  would only be durable on a clean shutdown, which a desktop app that is
  force quit does not get.
  """
  @spec touch(String.t()) :: :ok
  def touch(username) do
    GenServer.cast(Store.via(__MODULE__, username), :changed)

    Phoenix.PubSub.broadcast_from(
      MDTClient.PubSub,
      self(),
      topic(username),
      :http_history_changed
    )
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

  @doc "Returns compact history metadata without copying request or response bodies from ETS."
  @spec summaries(String.t(), String.t()) :: [summary()]
  def summaries(username, term \\ "") when is_binary(term) do
    table = table(username)

    case HistoryMetadata.normalize_search_text(term) do
      "" ->
        :ets.select_reverse(table, summary_match_spec())

      term ->
        # Compiled once rather than by every comparison.
        pattern = :binary.compile_pattern(term)

        table
        |> :ets.select_reverse(searchable_summary_match_spec())
        |> Search.filter(fn {_id, _description, _tags, _at, _duration, _method, _url, _status,
                             search_text} ->
          String.contains?(search_text, pattern)
        end)
        |> Enum.map(fn {id, description, tags, at, duration, method, url, status, _search_text} ->
          {id, description, tags, at, duration, method, url, status}
        end)
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

  @doc "Returns one entry without copying its response body out of ETS."
  @spec outline(String.t(), history_id()) :: {:ok, outline()} | :error
  def outline(username, identifier) do
    %{table: table, outlines: outlines} = handles(username)

    case :ets.lookup(outlines, identifier) do
      [{^identifier, response_outline}] ->
        try do
          {:ok,
           {
             identifier,
             :ets.lookup_element(table, identifier, 2),
             :ets.lookup_element(table, identifier, 3),
             response_outline
           }}
        rescue
          ArgumentError -> :error
        end

      [] ->
        :error
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

  @doc """
  Rewrites this identity's whole history in one step.

  `fun` is given the current entries, oldest first and without identifiers,
  and returns the new history the same way; it runs in the process that owns
  the table, so deletes and clears cannot interleave with it. Returned
  metadata must already carry its search text.

  The result is numbered afresh from the counter, in the order returned, so an
  identifier held from before — an open tab, a selection — finds nothing
  afterwards instead of landing on a different request. A request recorded
  while `fun` runs is kept, since only the entries it was given are removed.
  """
  @spec rewrite(String.t(), ([history_data()] -> [history_data()])) :: :ok
  def rewrite(username, fun) when is_function(fun, 1) do
    # Writing a large history can take a while, and a caller that gave up
    # partway would not know whether it landed.
    GenServer.call(Store.via(__MODULE__, username), {:rewrite, fun}, :infinity)
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
    restore(table, path, key, username)
    outlines = :ets.new(:http_history_outlines, [:public, :set, read_concurrency: true])
    build_outlines(table, outlines)

    counter = :atomics.new(1, signed: false)
    :ok = :atomics.put(counter, 1, latest_identifier(table))

    :ok =
      Store.publish(__MODULE__, username, %{table: table, outlines: outlines, counter: counter})

    {:ok,
     %{username: username, key: key, path: path, table: table, outlines: outlines, flush: nil},
     {:continue, :reindex}}
  end

  # Entries kept by a build that searched the whole inspected request and
  # response get the search text this one builds, a batch at a time and after
  # the history is already readable, so unlocking does not wait on it.
  @impl true
  def handle_continue(:reindex, state) do
    send(self(), {:reindex, :ets.first(state.table)})
    {:noreply, state}
  end

  @impl true
  def handle_call({:delete, identifier}, from, state) do
    case :ets.lookup(state.table, identifier) do
      [_entry] ->
        true = :ets.delete(state.table, identifier)
        true = :ets.delete(state.outlines, identifier)
        broadcast(state, from)
        {:reply, :ok, flushed(state)}

      [] ->
        {:reply, :error, state}
    end
  end

  @impl true
  def handle_call(:clear, from, state) do
    true = :ets.delete_all_objects(state.table)
    true = :ets.delete_all_objects(state.outlines)
    :ok = :atomics.put(counter(state.username), 1, 0)
    broadcast(state, from)
    {:reply, :ok, flushed(state)}
  end

  @impl true
  def handle_call({:rewrite, fun}, from, state) do
    before = :ets.tab2list(state.table)

    entries =
      before
      |> Enum.map(fn {_identifier, metadata, request, response} ->
        {metadata, request, response}
      end)
      |> fun.()

    count = length(entries)
    last = :atomics.add_get(counter(state.username), 1, count)

    entries
    |> Enum.with_index(last - count + 1)
    |> Enum.each(fn {{metadata, request, response}, identifier} ->
      true = :ets.insert(state.table, {identifier, metadata, request, response})
      true = :ets.insert(state.outlines, {identifier, response_outline(response)})
    end)

    # Written before the old entries go, so a reader never sees the history
    # empty partway.
    Enum.each(before, fn {identifier, _metadata, _request, _response} ->
      true = :ets.delete(state.table, identifier)
      true = :ets.delete(state.outlines, identifier)
    end)

    broadcast(state, from)
    {:reply, :ok, flushed(state)}
  end

  @impl true
  def handle_cast(:changed, state), do: {:noreply, changed(state)}

  @impl true
  def handle_info(:flush, state) do
    :ok = persist(state)
    {:noreply, %{state | flush: nil}}
  end

  def handle_info({:reindex, @end_of_table}, state), do: {:noreply, state}

  def handle_info({:reindex, identifier}, state) do
    {next, reindexed} = reindex(state.table, identifier, @reindex_batch, 0)
    send(self(), {:reindex, next})

    {:noreply, if(reindexed > 0, do: changed(state), else: state)}
  end

  # Unregister before flushing so nothing can grab a handle to a table that is
  # about to be destroyed.
  @impl true
  def terminate(_reason, state) do
    Store.release(__MODULE__, state.username)
    persist(state)
    :ok
  end

  defp handles(username) do
    case Store.fetch(__MODULE__, username) do
      {:ok, handles} ->
        handles

      :error ->
        raise "the vault for #{inspect(username)} is locked; sign in before reading its history"
    end
  end

  # Coalesced rather than written straight away: a burst of edits becomes one
  # write, while nothing waits longer than @flush_after to become durable.
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

  defp persist(state) do
    case File.write(state.path, Vault.seal(state.key, :ets.tab2list(state.table))) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("could not write history to #{state.path}: #{:file.format_error(reason)}",
          user: state.username,
          system: :http_client
        )

        :ok
    end
  end

  # A file that will not decrypt is kept, not overwritten: the key was already
  # proven by the verifier, so this is corruption rather than a wrong password.
  defp restore(table, path, key, username) do
    case File.read(path) do
      {:ok, blob} ->
        case Vault.open(key, blob) do
          {:ok, entries} when is_list(entries) ->
            true = :ets.insert(table, entries)
            :ok

          _unreadable ->
            quarantine(path, username)
        end

      {:error, _reason} ->
        :ok
    end
  end

  # Timestamped so a second failed start cannot overwrite the copy kept by the
  # first, which would turn a recoverable problem into data loss.
  defp quarantine(path, username) do
    corrupt = "#{path}.#{System.system_time(:second)}.corrupt"

    Logger.warning("history at #{path} could not be decrypted; kept as #{corrupt}",
      user: username,
      system: :http_client
    )

    File.rename(path, corrupt)
    :ok
  end

  defp reindex(_table, @end_of_table, _budget, reindexed), do: {@end_of_table, reindexed}
  defp reindex(_table, identifier, 0, reindexed), do: {identifier, reindexed}

  defp reindex(table, identifier, budget, reindexed) do
    reindexed =
      case :ets.lookup(table, identifier) do
        [{^identifier, metadata, request, response}] ->
          if String.contains?(metadata.search_text, "%req.request{") do
            updated = HistoryMetadata.with_search_text(metadata, request, response)

            # Replaced only if nobody changed the entry since it was read: a tag
            # added meanwhile already rebuilt the search text, and stays.
            replaced =
              :ets.select_replace(table, [
                {{identifier, metadata, :"$1", :"$2"}, [],
                 [{{identifier, {:const, updated}, :"$1", :"$2"}}]}
              ])

            reindexed + replaced
          else
            reindexed
          end

        [] ->
          reindexed
      end

    reindex(table, :ets.next(table, identifier), budget - 1, reindexed)
  end

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

  defp build_outlines(table, outlines) do
    :ets.foldl(
      fn {identifier, _metadata, _request, response}, :ok ->
        true = :ets.insert(outlines, {identifier, response_outline(response)})
        :ok
      end,
      :ok,
      table
    )
  end

  defp topic(username), do: "http_history:" <> Accounts.id(username)

  defp broadcast(state, {caller, _tag}) do
    Phoenix.PubSub.broadcast_from(
      MDTClient.PubSub,
      caller,
      topic(state.username),
      :http_history_changed
    )
  end

  defp response_outline(nil), do: :sample

  defp response_outline(%Req.Response{} = response) do
    {:response, response.status, response.headers, Utils.response_body_size(response)}
  end

  defp response_outline(error), do: {:error, error}

  defp summary_match_spec do
    summary_match_spec(fn id,
                          description,
                          tags,
                          at,
                          duration,
                          method,
                          url,
                          status,
                          _search_text ->
      {id, description, tags, at, duration, method, url, status}
    end)
  end

  defp searchable_summary_match_spec do
    summary_match_spec(fn id, description, tags, at, duration, method, url, status, search_text ->
      {id, description, tags, at, duration, method, url, status, search_text}
    end)
  end

  defp summary_match_spec(result) do
    sample_summary = result.(:"$1", :"$2", :"$3", :"$4", :"$5", :"$7", :"$8", 0, :"$6")

    response_summary =
      result.(
        :"$1",
        :"$2",
        :"$3",
        :"$4",
        :"$5",
        :"$7",
        :"$8",
        :"$9",
        :"$6"
      )

    error_summary =
      result.(
        :"$1",
        :"$2",
        :"$3",
        :"$4",
        :"$5",
        :"$7",
        :"$8",
        599,
        :"$6"
      )

    [
      {
        {:"$1",
         %{
           description: :"$2",
           tags: :"$3",
           completed_at: :"$4",
           duration_ms: :"$5",
           search_text: :"$6"
         }, %{method: :"$7", url: :"$8"}, nil},
        [],
        [{sample_summary}]
      },
      {
        {:"$1",
         %{
           description: :"$2",
           tags: :"$3",
           completed_at: :"$4",
           duration_ms: :"$5",
           search_text: :"$6"
         }, %{method: :"$7", url: :"$8"}, %{__struct__: Req.Response, status: :"$9"}},
        [],
        [{response_summary}]
      },
      {
        {:"$1",
         %{
           description: :"$2",
           tags: :"$3",
           completed_at: :"$4",
           duration_ms: :"$5",
           search_text: :"$6"
         }, %{method: :"$7", url: :"$8"}, %{__struct__: :"$10"}},
        [{:"=/=", :"$10", Req.Response}],
        [{error_summary}]
      }
    ]
  end
end
