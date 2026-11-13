defmodule MDTClient.Sandbox.EgressCorpusTest do
  @moduledoc """
  The corpus of malformed and ambiguous requests (`MDTClient.SandboxCorpus`)
  through the proxy, each carrying the placeholder of a grant that is on
  with every use allowed: nothing but the reading of the request stands
  between it and the real value.
  """
  use ExUnit.Case, async: true

  alias MDTClient.{Sandbox, SandboxCorpus, SandboxProxy}

  @real "ghp_REAL_SECRET_VALUE"

  setup do
    %{username: username} = MDTClient.VaultHelpers.unlocked_identity("corpus")

    {:ok, grant} =
      Sandbox.create_grant(username, %{
        "kind" => "token",
        "name" => "GitHub",
        "purpose" => "The GitHub API",
        "hosts" => SandboxCorpus.host(),
        "env" => "GH_TOKEN",
        "prefix" => "ghp_",
        "value" => @real
      })

    {:ok, grant} = Sandbox.turn_on(username, grant.id, :until_off, :all)
    %{username: username, grant: grant, net: SandboxProxy.start(username)}
  end

  # What the host received, when anything did.
  defp received(response) do
    case String.split(response, "RECEIVED:\n", parts: 2) do
      [_head, received] -> received
      [_nothing] -> nil
    end
  end

  defp status(response) do
    case response do
      "HTTP/1.1 " <> <<status::binary-size(3), _::binary>> -> String.to_integer(status)
      _other -> nil
    end
  end

  test "each one is refused whole, or reaches the host as one request MDT wrote", context do
    entries = SandboxCorpus.entries(context.grant.placeholder)
    assert length(entries) > 50

    outcomes =
      entries
      |> Task.async_stream(
        fn entry ->
          {entry, SandboxProxy.https(context.net, SandboxCorpus.host(), entry.bytes)}
        end,
        max_concurrency: 16,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, outcome} -> outcome end)

    wrong =
      for {entry, response} <- outcomes,
          problem = problem(entry, response, context.grant.placeholder),
          do: "#{entry.name}: #{problem}"

    assert wrong == [], Enum.join(wrong, "\n")
  end

  defp problem(%{expect: {:refused, wanted}}, response, _placeholder) do
    cond do
      received(response) != nil -> "reached the host: #{inspect(received(response))}"
      String.contains?(response, @real) -> "the real value came back"
      status(response) != wanted -> "answered #{inspect(status(response))}, not #{wanted}"
      true -> nil
    end
  end

  defp problem(%{expect: expect}, response, placeholder) do
    case received(response) do
      nil ->
        "refused with #{inspect(status(response))}"

      received ->
        [head, behind] = String.split(received, "\r\n\r\n", parts: 2)
        [line | headers] = String.split(head, "\r\n")
        hosts = Enum.filter(headers, &String.starts_with?(&1, "host:"))

        cond do
          not (line =~ ~r"\A[A-Z]+ [\x21-\x7e]+ HTTP/1\.[01]\z") ->
            "an odd request line: #{inspect(line)}"

          not Enum.all?(headers, &(&1 =~ ~r/\A[a-z0-9-]+: [^\r\n\0]*\z/)) ->
            "a header MDT didn't write: #{inspect(headers)}"

          hosts != ["host: #{SandboxCorpus.host()}"] ->
            "the wrong Host: #{inspect(hosts)}"

          length(String.split(received, @real)) != 2 ->
            "the real value is there #{length(String.split(received, @real)) - 1} times"

          String.contains?(head, placeholder) ->
            "the placeholder went out in the head"

          expect == :forwarded and String.contains?(behind, placeholder) ->
            "a placeholder went out behind the head"

          # The request hidden behind the first one arrives, as the bytes
          # the VM sent: with its placeholder, which opens nothing.
          expect == :forwarded_once and
              not String.contains?(behind, "Authorization: token #{placeholder}\r\nX-Second: yes") ->
            "what was sent behind the request didn't arrive as it was sent"

          true ->
            nil
        end
    end
  end
end
