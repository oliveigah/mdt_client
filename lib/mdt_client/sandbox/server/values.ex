defmodule MDTClient.Sandbox.Server.Values do
  @moduledoc """
  The real values, at the one place they leave the vault: fetching a grant's
  value, stored or minted by your command, and answering the proxy with the
  request's headers carrying it, or with a refusal.

  A value is put into a request only here, after
  `MDTClient.Sandbox.Policy` or your decision let that request through. Runs
  in the server's process (`MDTClient.Sandbox.Server.State`).
  """

  alias MDTClient.Sandbox.{Grant, HostRun, Placeholder}
  alias MDTClient.Sandbox.Server.{State}

  @mint_fresh_ms 10 * 60_000

  @doc """
  Fetches the value, then answers the proxy with the headers it carries.
  """
  def forward(state, grant, request, from) do
    with_value(state, grant, fn state, result ->
      case result do
        {:ok, value} ->
          GenServer.reply(
            from,
            {:forward, Placeholder.swap(request.headers, grant.placeholder, value),
             [{value, grant.placeholder}]}
          )

          State.used(state, grant.id)

        {:error, :no_value} ->
          GenServer.reply(
            from,
            deny(503, "mdt_no_value", "#{grant.name} has no value yet.", grant)
          )

          State.log(
            state,
            request_event(request, grant, :refused, "#{grant.name} has no value set")
          )

        {:error, message} ->
          GenServer.reply(
            from,
            deny(502, "mdt_mint_failed", "Could not mint a token for #{grant.name}.", grant)
          )

          State.log(state, request_event(request, grant, :refused, "Minting failed: #{message}"))
      end
    end)
  end

  defp with_value(state, %Grant{source: :stored} = grant, k) do
    case state.values do
      %{} = values when is_map_key(values, grant.id) -> k.(state, {:ok, values[grant.id]})
      _ -> k.(state, {:error, :no_value})
    end
  end

  defp with_value(state, %Grant{source: {:minted, command}} = grant, k) do
    fresh_since = System.monotonic_time(:millisecond) - @mint_fresh_ms

    case {state.minted[grant.id], state.minting[grant.id]} do
      {{value, at}, _} when at > fresh_since ->
        k.(state, {:ok, value})

      {_, [_ | _] = waiting} ->
        %{state | minting: Map.put(state.minting, grant.id, waiting ++ [k])}

      _none ->
        state
        |> State.task({:mint, grant.id}, fn -> mint(command) end)
        |> Map.update!(:minting, &Map.put(&1, grant.id, [k]))
    end
  end

  defp mint(command) do
    case System.cmd("timeout", ["30", "bash", "-lc", command],
           stderr_to_stdout: false,
           env: HostRun.home_env()
         ) do
      {output, 0} ->
        case String.trim(output) do
          "" -> {:error, "the command printed nothing"}
          token -> {:ok, token}
        end

      {_output, status} ->
        {:error, "the command exited with #{status}"}
    end
  end

  @doc """
  The proxy's refusal of a request: a status, and a JSON body with the reason and the grant's name.
  """
  def deny(status, code, message, grant) do
    body =
      Jason.encode!(%{
        error: message,
        code: code,
        grant: grant && grant.name,
        by: "MDT agent sandbox"
      })

    {:deny, status, body}
  end

  @doc """
  The log's event for a request that carried a grant's placeholder.
  """
  def request_event(request, grant, outcome, summary) do
    %{
      outcome: outcome,
      summary: summary,
      host: request.host,
      port: 443,
      grant_id: grant.id,
      method: request.method,
      path: request.path
    }
  end
end
