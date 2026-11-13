defmodule MDTClient.Sandbox.Roots do
  @moduledoc """
  The root certificates this machine trusts, as one PEM file, for the
  connections the proxy makes itself.

  Erlang's `ssl` takes a `cacerts` list in again on every connect: with the
  119 roots here that cost about 2 ms a request, and half the throughput at
  64 connections at once. A `cacertfile` it reads once and shares between
  connections. So the roots are written to a file once per run of MDT, in
  MDT's own folder, where only you can write.
  """

  alias MDTClient.Accounts

  @doc "The file, written on first use."
  @spec file() :: Path.t()
  def file do
    case :persistent_term.get(__MODULE__, nil) do
      path when is_binary(path) ->
        if File.regular?(path), do: path, else: write!()

      nil ->
        write!()
    end
  end

  defp write! do
    path = Path.join(Accounts.root(), "roots.pem")

    pem =
      :public_key.cacerts_get()
      |> Enum.map(fn {:cert, der, _decoded} -> {:Certificate, der, :not_encrypted} end)
      |> :public_key.pem_encode()

    # Written aside and renamed: a connection never reads half a file.
    partial = "#{path}.#{System.unique_integer([:positive])}.part"
    File.mkdir_p!(Path.dirname(path))
    File.write!(partial, pem)
    File.rename!(partial, path)
    :persistent_term.put(__MODULE__, path)
    path
  end
end
