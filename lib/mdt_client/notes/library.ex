defmodule MDTClient.Notes.Library do
  @moduledoc """
  Owns one identity's notes.

  They live in this process and reach disk only through `MDTClient.Vault`, so
  a note never touches the filesystem in the clear. One process runs per
  unlocked identity, started by `MDTClient.Vault.Store`; every function takes
  the username it belongs to.

  This module is the only way in, for the notes page and for anything else
  that writes notes. Every change is broadcast to the processes that
  `subscribe/1`, all but the one that made it, so a page shows what was
  written elsewhere without asking. Lists come back as summaries, built here,
  so searching as someone types copies titles and snippets rather than every
  body.
  """

  use GenServer

  require Logger

  alias MDTClient.Accounts
  alias MDTClient.Notes.Note
  alias MDTClient.Vault
  alias MDTClient.Vault.Store

  @library_file "notes.bin"
  @flush_after 250

  @type summary :: %{
          id: String.t(),
          title: String.t(),
          done_at: DateTime.t() | nil,
          updated_at: DateTime.t(),
          excerpt: String.t() | nil,
          snippet: {String.t(), String.t(), String.t()} | nil
        }

  @typedoc """
  Sent to subscribers when a note changes, naming it, or `:all` when every
  note was replaced at once, as by an import.
  """
  @type message :: {:notes_changed, String.t() | :all}

  @doc "Starts the library for one unlocked identity."
  def start_link(opts) do
    username = Keyword.fetch!(opts, :username)
    GenServer.start_link(__MODULE__, opts, name: Store.via(__MODULE__, username))
  end

  @doc "Subscribes the caller to the `t:message/0`s of changes made by others."
  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(username), do: Phoenix.PubSub.subscribe(MDTClient.PubSub, topic(username))

  @doc """
  Summaries of the notes holding every word of `term`, the most recently
  changed first. A blank term lists them all.
  """
  @spec list(String.t(), String.t()) :: [summary()]
  def list(username, term \\ "") when is_binary(term) do
    call(username, {:list, Note.terms(term)})
  end

  @doc "The note changed last, if there is one."
  @spec latest(String.t()) :: {:ok, Note.t()} | :error
  def latest(username), do: call(username, :latest)

  @doc "One note, body and all."
  @spec get(String.t(), String.t()) :: {:ok, Note.t()} | :error
  def get(username, id), do: call(username, {:get, id})

  @doc "Every note, the oldest change first."
  @spec all(String.t()) :: [Note.t()]
  def all(username), do: call(username, :all)

  @doc """
  Writes `:title` and `:body` into the note `id`, creating it if it is not
  there yet.

  A note exists from its first save, so one opened and left blank does not
  clutter the list.
  """
  @spec save(String.t(), String.t(), map()) :: {:ok, Note.t()} | {:error, :invalid_id}
  def save(username, id, attrs) when is_map(attrs) do
    if Note.id?(id), do: call(username, {:save, id, attrs}), else: {:error, :invalid_id}
  end

  @doc """
  Marks a note done, or open again. Asking for the state it is already in
  changes nothing, so it is safe to repeat.
  """
  @spec set_done(String.t(), String.t(), boolean()) :: {:ok, Note.t()} | :error
  def set_done(username, id, done?) when is_boolean(done?) do
    call(username, {:set_done, id, done?})
  end

  @doc "Deletes one note."
  @spec delete(String.t(), String.t()) :: :ok | :error
  def delete(username, id), do: call(username, {:delete, id})

  @doc """
  Replaces every note with what `fun` returns when given them all, oldest
  change first. It runs in this process, so no save can land in between.
  """
  @spec rewrite(String.t(), ([Note.t()] -> [Note.t()])) :: :ok
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
       notes: restore(path, key, username),
       flush: nil
     }}
  end

  @impl true
  def handle_call({:list, terms}, _from, state) do
    summaries =
      for note <- newest_first(state.notes), Note.matches?(note, terms) do
        %{
          id: note.id,
          title: note.title,
          done_at: note.done_at,
          updated_at: note.updated_at,
          excerpt: Note.excerpt(note),
          snippet: Note.snippet(note, terms)
        }
      end

    {:reply, summaries, state}
  end

  def handle_call(:latest, _from, state) do
    case newest_first(state.notes) do
      [note | _rest] -> {:reply, {:ok, note}, state}
      [] -> {:reply, :error, state}
    end
  end

  def handle_call({:get, id}, _from, state) do
    {:reply, Map.fetch(state.notes, id), state}
  end

  def handle_call(:all, _from, state) do
    {:reply, state.notes |> newest_first() |> Enum.reverse(), state}
  end

  def handle_call({:save, id, attrs}, from, state) do
    attrs = Map.take(attrs, [:title, :body])

    case Map.fetch(state.notes, id) do
      {:ok, note} ->
        change(note, attrs, from, state)

      :error ->
        note = Note.new(Map.put(attrs, :id, id))
        broadcast(state, from, id)
        {:reply, {:ok, note}, state |> put(note) |> changed()}
    end
  end

  def handle_call({:set_done, id, done?}, from, state) do
    case Map.fetch(state.notes, id) do
      {:ok, note} -> change(note, %{done: done?}, from, state)
      :error -> {:reply, :error, state}
    end
  end

  def handle_call({:delete, id}, from, state) do
    if Map.has_key?(state.notes, id) do
      broadcast(state, from, id)
      {:reply, :ok, flushed(%{state | notes: Map.delete(state.notes, id)})}
    else
      {:reply, :error, state}
    end
  end

  def handle_call({:rewrite, fun}, from, state) do
    notes =
      state.notes
      |> newest_first()
      |> Enum.reverse()
      |> fun.()
      |> Map.new(&{&1.id, &1})

    broadcast(state, from, :all)
    {:reply, :ok, flushed(%{state | notes: notes})}
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

  defp change(note, attrs, from, state) do
    case Note.update(note, attrs) do
      ^note ->
        {:reply, {:ok, note}, state}

      updated ->
        broadcast(state, from, note.id)
        {:reply, {:ok, updated}, state |> put(updated) |> changed()}
    end
  end

  # Everyone but the caller, who has the answer to its own call already.
  defp broadcast(state, {caller, _tag}, id) do
    Phoenix.PubSub.broadcast_from(
      MDTClient.PubSub,
      caller,
      topic(state.username),
      {:notes_changed, id}
    )
  end

  defp topic(username), do: "notes:" <> Accounts.id(username)

  defp put(state, note), do: %{state | notes: Map.put(state.notes, note.id, note)}

  # Coalesced rather than written straight away: typing saves every pause,
  # and a burst of them becomes one write, while nothing waits longer than
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

  defp newest_first(notes) do
    notes |> Map.values() |> Enum.sort_by(& &1.updated_at, {:desc, DateTime})
  end

  # Written aside and renamed into place, so a crash partway through a write
  # leaves the previous file rather than half of a new one.
  defp persist(state) do
    partial = "#{state.path}.part"
    blob = Vault.seal(state.key, Map.values(state.notes))

    with :ok <- File.write(partial, blob),
         :ok <- File.rename(partial, state.path) do
      :ok
    else
      {:error, reason} ->
        Logger.error(
          "could not write notes to #{state.path}: #{:file.format_error(reason)}",
          user: state.username,
          system: :notes
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
          {:ok, notes} when is_list(notes) ->
            Map.new(notes, &{&1.id, upgrade(&1)})

          _unreadable ->
            quarantine(path, username)
            %{}
        end

      {:error, _reason} ->
        %{}
    end
  end

  # Rebuilt through the struct, so a note kept by a build whose struct had
  # fewer fields comes back with this build's defaults for the ones it lacks.
  defp upgrade(note), do: struct(Note, Map.from_struct(note))

  # Timestamped so a second failed start cannot overwrite the copy kept by the
  # first, which would turn a recoverable problem into data loss.
  defp quarantine(path, username) do
    corrupt = "#{path}.#{System.system_time(:second)}.corrupt"

    Logger.warning("notes at #{path} could not be decrypted; kept as #{corrupt}",
      user: username,
      system: :notes
    )

    File.rename(path, corrupt)
  end
end
