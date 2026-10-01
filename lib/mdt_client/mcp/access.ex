defmodule MDTClient.MCP.Access do
  @moduledoc """
  One persistent agent credential per local identity.

  Only a token hash is saved, encrypted with the identity's vault key. The
  vault starts this process on unlock and stops it on lock, so the same token
  resumes working after unlocking or restarting MDT without retaining access
  to a locked identity.
  """
  use GenServer

  require Logger

  alias MDTClient.Accounts
  alias MDTClient.Vault
  alias MDTClient.Vault.Store

  @registry MDTClient.MCP.Registry
  @credential_file "mcp_access.bin"

  def start_link(opts) do
    username = Keyword.fetch!(opts, :username)
    GenServer.start_link(__MODULE__, opts, name: Store.via(__MODULE__, username))
  end

  @doc "Generates and durably saves a token, replacing the previous one."
  def issue(username), do: call(username, :issue)

  @doc "Permanently revokes this identity's token."
  def revoke(username), do: call(username, :revoke)

  def enabled?(username) do
    case Store.fetch(__MODULE__, username) do
      {:ok, %{enabled?: enabled?}} -> enabled?
      :error -> false
    end
  end

  def subscribe(username), do: Phoenix.PubSub.subscribe(MDTClient.PubSub, topic(username))

  def authorize(token) when is_binary(token) do
    case Registry.lookup(@registry, hash(token)) do
      [{pid, username}] ->
        if Store.whereis(__MODULE__, username) == pid and Store.open?(username),
          do: {:ok, username},
          else: :error

      [] ->
        :error
    end
  end

  def authorize(_token), do: :error

  defp call(username, request) do
    if Store.open?(username),
      do: GenServer.call(Store.via(__MODULE__, username), request),
      else: {:error, :locked}
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    username = Keyword.fetch!(opts, :username)
    key = Keyword.fetch!(opts, :key)
    path = Accounts.store_path(username, @credential_file)
    hash = restore(path, key)
    register(hash, username)
    :ok = Store.publish(__MODULE__, username, %{enabled?: hash != nil})
    {:ok, %{username: username, key: key, path: path, hash: hash}}
  end

  @impl true
  def handle_call(:issue, {caller, _tag}, state) do
    token = 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    hash = hash(token)
    blob = Vault.seal(state.key, %{version: 1, hash: hash})

    with :ok <- File.write(state.path <> ".part", blob),
         :ok <- File.rename(state.path <> ".part", state.path) do
      {:reply, {:ok, token}, change(state, hash, caller)}
    else
      {:error, reason} ->
        log_storage_error(reason)
        {:reply, {:error, :storage}, state}
    end
  end

  def handle_call(:revoke, {caller, _tag}, state) do
    case File.rm(state.path) do
      result when result in [:ok, {:error, :enoent}] ->
        {:reply, :ok, change(state, nil, caller)}

      {:error, reason} ->
        log_storage_error(reason)
        {:reply, {:error, :storage}, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    unregister(state.hash)
    :ok
  end

  defp change(state, hash, caller) do
    unregister(state.hash)
    register(hash, state.username)
    :ok = Store.publish(__MODULE__, state.username, %{enabled?: hash != nil})

    Phoenix.PubSub.broadcast_from(
      MDTClient.PubSub,
      caller,
      topic(state.username),
      :mcp_access_changed
    )

    %{state | hash: hash}
  end

  defp register(nil, _username), do: :ok

  defp register(hash, username) do
    {:ok, _owner} = Registry.register(@registry, hash, username)
    :ok
  end

  defp unregister(nil), do: :ok
  defp unregister(hash), do: Registry.unregister(@registry, hash)

  defp restore(path, key) do
    case File.read(path) do
      {:ok, blob} ->
        case Vault.open(key, blob) do
          {:ok, %{version: 1, hash: hash}} when is_binary(hash) and byte_size(hash) == 32 ->
            hash

          _unreadable ->
            Logger.warning("could not decrypt the saved MCP credential", system: :mcp)
            nil
        end

      {:error, :enoent} ->
        nil

      {:error, reason} ->
        log_storage_error(reason)
        nil
    end
  end

  defp log_storage_error(reason) do
    Logger.error("could not persist MCP access: #{:file.format_error(reason)}", system: :mcp)
  end

  defp hash(token), do: :crypto.hash(:sha256, token)
  defp topic(username), do: "mcp_access:" <> Accounts.id(username)
end
