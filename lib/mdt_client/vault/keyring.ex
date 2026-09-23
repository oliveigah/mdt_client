defmodule MDTClient.Vault.Keyring do
  @moduledoc """
  Seals and opens with an unlocked identity's key, without handing it out.

  It is one of the processes `MDTClient.Vault.Store` starts per identity, so
  it lives and dies with the vault. Anything that needs data sealed under the
  identity's own key — an export, which the identity's password then opens
  anywhere — asks this process to do it rather than holding the key itself.

  Alongside the key it keeps the parameters that derived it, read from
  `vault.json` at unlock, so a sealed blob can say how to derive its key again
  from the password.
  """

  use GenServer

  alias MDTClient.Accounts
  alias MDTClient.Vault
  alias MDTClient.Vault.Store

  @doc "Starts the keyring for one unlocked identity."
  def start_link(opts) do
    username = Keyword.fetch!(opts, :username)
    GenServer.start_link(__MODULE__, opts, name: Store.via(__MODULE__, username))
  end

  @doc "The KDF parameters and base64 salt the identity's key was derived with."
  @spec kdf(String.t()) :: map()
  def kdf(username), do: GenServer.call(Store.via(__MODULE__, username), :kdf)

  @doc """
  Seals a term under the identity's key, as `MDTClient.Vault.seal/2` does.

  Pass large data as a binary: binaries cross to this process by reference,
  other terms are copied.
  """
  @spec seal(String.t(), term()) :: binary()
  def seal(username, term) do
    GenServer.call(Store.via(__MODULE__, username), {:seal, term}, :infinity)
  end

  @doc "Opens a blob sealed under the identity's key, as `MDTClient.Vault.open/2` does."
  @spec open(String.t(), binary()) :: {:ok, term()} | :error
  def open(username, blob) when is_binary(blob) do
    GenServer.call(Store.via(__MODULE__, username), {:open, blob}, :infinity)
  end

  @impl true
  def init(opts) do
    username = Keyword.fetch!(opts, :username)
    {:ok, kdf} = Accounts.kdf(username)
    {:ok, %{key: Keyword.fetch!(opts, :key), kdf: kdf}}
  end

  @impl true
  def handle_call(:kdf, _from, state), do: {:reply, state.kdf, state}
  def handle_call({:seal, term}, _from, state), do: {:reply, Vault.seal(state.key, term), state}
  def handle_call({:open, blob}, _from, state), do: {:reply, Vault.open(state.key, blob), state}
end
