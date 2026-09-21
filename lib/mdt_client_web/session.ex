defmodule MDTClientWeb.Session do
  @moduledoc """
  Maps the opaque token in the cookie to the identity that opened a vault.

  The encryption key is deliberately absent: it lives only in the vault's
  store process. Phoenix session cookies are signed but readable, so nothing
  secret may travel in one.
  """

  use GenServer

  @table __MODULE__

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))
  end

  @doc "Issues a token for a signed in identity."
  @spec create(String.t()) :: String.t()
  def create(username) do
    token = 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    true = :ets.insert(@table, {token, %{username: username, opened_at: DateTime.utc_now()}})
    token
  end

  @doc "Looks a token up."
  @spec fetch(String.t() | nil) :: {:ok, map()} | :error
  def fetch(token) when is_binary(token) do
    case :ets.lookup(@table, token) do
      [{^token, session}] -> {:ok, session}
      [] -> :error
    end
  end

  def fetch(_token), do: :error

  @doc "Forgets a token."
  @spec delete(String.t() | nil) :: :ok
  def delete(token) when is_binary(token) do
    true = :ets.delete(@table, token)
    :ok
  end

  def delete(_token), do: :ok

  @impl true
  def init(:ok) do
    @table = :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end
end
