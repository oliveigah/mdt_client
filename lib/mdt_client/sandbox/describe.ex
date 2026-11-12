defmodule MDTClient.Sandbox.Describe do
  @moduledoc """
  Turns a request carrying a placeholder into what an approval shows and what
  rules match on.

    * `tags` - what kind of request it is: `read`, `write`, `git_fetch`,
      `git_push`, `graphql_query` or `graphql_mutation`. A rule matches when
      its tag is among them; `any` matches everything.
    * `title`, `facts` - worked out from the request itself.
    * `claims` - text the agent wrote (titles, bodies, messages), kept apart
      so it can never read as a fact.
    * `pattern` - what "allow similar" lets through: the same method and
      endpoint, and for GraphQL the same operation.

  Only the start of the body is looked at, at most what `Egress` reads before
  asking (64 KiB): enough for git's ref updates, which come before the pack,
  and for GraphQL documents.
  """

  @type request :: %{
          host: String.t(),
          method: String.t(),
          path: String.t(),
          headers: [{String.t(), String.t()}],
          body: binary()
        }

  @type t :: %{
          tags: [String.t()],
          title: String.t(),
          facts: [{String.t(), String.t()}],
          claims: [{String.t(), String.t()}],
          pattern: String.t()
        }

  @claim_keys ~w(title body message description name)

  @doc "Describes a request."
  @spec request(request()) :: t()
  def request(%{method: method, path: path} = request) do
    {route, query} = split_query(path)

    cond do
      String.ends_with?(route, "/git-receive-pack") and method == "POST" -> push(request, route)
      String.ends_with?(route, "/git-upload-pack") and method == "POST" -> fetch(request, route)
      String.ends_with?(route, "/info/refs") -> refs(request, route, query)
      route == "/graphql" and method == "POST" -> graphql(request)
      true -> rest(request, route)
    end
  end

  defp push(request, route) do
    repo = repository(route)
    updates = ref_updates(request.body)

    title =
      case updates do
        [{ref, _old, _new}] -> "Push #{short_ref(ref)} to #{repo}"
        [] -> "Push to #{repo}"
        many -> "Push #{length(many)} refs to #{repo}"
      end

    %{
      tags: ["git_push"],
      title: title,
      facts:
        [{"Repository", repo}] ++
          Enum.map(updates, fn {ref, old, new} -> {"Ref", "#{ref}  #{update_words(old, new)}"} end) ++
          client(request),
      claims: [],
      pattern: "POST #{request.host}#{route}"
    }
  end

  defp fetch(request, route) do
    %{
      tags: ["git_fetch"],
      title: "Fetch from #{repository(route)}",
      facts: [{"Repository", repository(route)}] ++ client(request),
      claims: [],
      pattern: "POST #{request.host}#{route}"
    }
  end

  defp refs(request, route, query) do
    service = URI.decode_query(query || "")["service"] || "git-upload-pack"

    %{
      tags: ["read", if(service == "git-receive-pack", do: "git_push_refs", else: "git_fetch")],
      title: "List refs of #{repository(route)}",
      facts: [{"Repository", repository(route)}, {"For", service}] ++ client(request),
      claims: [],
      pattern: "#{request.method} #{request.host}#{route}"
    }
  end

  defp graphql(request) do
    {kind, name, variables} =
      case Jason.decode(request.body) do
        {:ok, %{"query" => query} = doc} when is_binary(query) ->
          {kind, name} = operation(query, doc["operationName"])
          {kind, name, doc["variables"] || %{}}

        _unreadable ->
          {"unknown", nil, %{}}
      end

    label = Enum.join(Enum.reject([kind, name], &is_nil/1), " ")

    %{
      tags: [if(kind == "mutation", do: "graphql_mutation", else: "graphql_query")],
      title: "GraphQL #{label} on #{request.host}",
      facts: [{"Operation", label}] ++ repository_facts(variables) ++ client(request),
      claims: claims(variables),
      pattern: "POST #{request.host}/graphql · #{label}"
    }
  end

  defp rest(request, route) do
    read? = request.method in ["GET", "HEAD", "OPTIONS"]

    body_claims =
      case Jason.decode(request.body) do
        {:ok, %{} = json} -> claims(json)
        _ -> []
      end

    %{
      tags: [if(read?, do: "read", else: "write")],
      title: "#{request.method} #{request.host}#{route}",
      facts: [{"Endpoint", "#{request.method} #{route}"}] ++ client(request),
      claims: body_claims,
      pattern: "#{request.method} #{request.host}#{route}"
    }
  end

  @doc """
  The ref updates at the start of a git-receive-pack body, as
  `{ref, old, new}`: pkt-lines of `old new ref`, ended by a flush.
  """
  @spec ref_updates(binary()) :: [{String.t(), String.t(), String.t()}]
  def ref_updates(body), do: pkt_lines(body, [])

  defp pkt_lines("0000" <> _rest, acc), do: Enum.reverse(acc)

  defp pkt_lines(<<hex::binary-size(4), rest::binary>>, acc) do
    with {length, ""} <- Integer.parse(hex, 16),
         true <- length >= 4,
         <<line::binary-size(length - 4), rest::binary>> <- rest,
         [old, new, ref | _] <-
           line |> String.split(<<0>>) |> hd() |> String.trim() |> String.split(" ") do
      pkt_lines(rest, [{ref, old, new} | acc])
    else
      _ -> Enum.reverse(acc)
    end
  end

  defp pkt_lines(_body, acc), do: Enum.reverse(acc)

  defp update_words(old, new) do
    cond do
      zero?(old) -> "new at #{short(new)}"
      zero?(new) -> "deleted (was #{short(old)})"
      true -> "#{short(old)} → #{short(new)}"
    end
  end

  defp zero?(sha), do: sha != "" and String.trim(sha, "0") == ""
  defp short(sha), do: binary_part(sha, 0, min(7, byte_size(sha)))
  defp short_ref("refs/heads/" <> branch), do: branch
  defp short_ref("refs/tags/" <> tag), do: "tag #{tag}"
  defp short_ref(ref), do: ref

  defp operation(query, operation_name) do
    trimmed = String.trim_leading(query)

    case Regex.run(~r/^(query|mutation|subscription)\b\s*([A-Za-z_][A-Za-z0-9_]*)?/, trimmed) do
      [_, kind, name] -> {kind, operation_name || name}
      [_, kind] -> {kind, operation_name || first_field(trimmed)}
      nil -> {"query", operation_name || first_field(trimmed)}
    end
  end

  defp first_field(query) do
    case Regex.run(~r/\{\s*([A-Za-z_][A-Za-z0-9_]*)/, query) do
      [_, field] -> field
      nil -> nil
    end
  end

  defp repository_facts(variables) do
    for key <- ["owner", "name", "repo", "repository", "repositoryId"],
        value = deep_get(variables, key),
        is_binary(value),
        do: {key |> String.capitalize(), value}
  end

  # Free text the agent chose: shown as its words, never as facts.
  defp claims(map) do
    for key <- @claim_keys,
        value = deep_get(map, key),
        is_binary(value),
        value != "",
        do: {String.capitalize(key), String.slice(value, 0, 600)}
  end

  defp deep_get(%{} = map, key) do
    Map.get(map, key) || Enum.find_value(Map.values(map), &deep_get(&1, key))
  end

  defp deep_get(_other, _key), do: nil

  defp client(request) do
    case List.keyfind(request.headers, "user-agent", 0) do
      {_, agent} -> [{"Client", String.slice(agent, 0, 80)}]
      nil -> []
    end
  end

  defp repository(route) do
    route
    |> String.split("/", trim: true)
    |> Enum.take(2)
    |> Enum.join("/")
    |> String.trim_trailing(".git")
  end

  defp split_query(path) do
    case String.split(path, "?", parts: 2) do
      [route, query] -> {route, query}
      [route] -> {route, nil}
    end
  end
end
