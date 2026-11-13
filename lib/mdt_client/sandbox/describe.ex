defmodule MDTClient.Sandbox.Describe do
  @moduledoc """
  Turns a request carrying a placeholder into what an approval shows. It
  decides nothing: every use waits for you unless an allowance covers it.

    * `title`, `facts` - worked out from the request itself: git's ref
      updates, a GraphQL operation, a REST endpoint.
    * `claims` - text the agent wrote (titles, bodies, messages), kept apart
      so it can never read as a fact.
    * `pattern` - what "allow similar" lets through: the same method and
      endpoint, and for GraphQL the same document.

  Only the start of the body is looked at, at most what `Egress` reads before
  asking (64 KiB): enough for git's ref updates, which come before the pack,
  and for GraphQL documents.

  The request is the VM's, bytes of its choosing. So every text that comes
  out shows all it holds (`MDTClient.Sandbox.Shown`), and a request this
  can't make sense of is described by its method and host instead of
  failing: the sandbox's own process runs this.
  """

  require Logger

  alias MDTClient.Sandbox.{GraphQL, Shown}

  @type request :: %{
          host: String.t(),
          method: String.t(),
          path: String.t(),
          headers: [{String.t(), String.t()}],
          body: binary()
        }

  @type t :: %{
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

    described =
      try do
        cond do
          String.ends_with?(route, "/git-receive-pack") and method == "POST" ->
            push(request, route)

          String.ends_with?(route, "/git-upload-pack") and method == "POST" ->
            fetch(request, route)

          String.ends_with?(route, "/info/refs") ->
            refs(request, route, query)

          route == "/graphql" and method == "POST" ->
            graphql(request)

          true ->
            rest(request, route)
        end
      rescue
        error ->
          Logger.warning("a request could not be described: #{Exception.message(error)}",
            system: :sandbox
          )

          %{
            title: "#{method} #{request.host}#{route}",
            facts: [{"Endpoint", "#{method} #{route}"}],
            claims: [],
            pattern: "#{method} #{request.host}#{route}"
          }
      end

    %{
      title: Shown.text(described.title),
      facts: Enum.map(described.facts, &shown/1),
      claims: Enum.map(described.claims, &shown/1),
      pattern: exact(described.pattern)
    }
  end

  defp shown({label, value}), do: {Shown.text(label), Shown.text(value)}

  # A pattern is compared, so two that differ must stay different once they
  # are made safe to show: one that had to change carries a digest of what
  # it was.
  defp exact(pattern) do
    case Shown.text(pattern) do
      ^pattern -> pattern
      changed -> changed <> " · " <> short_digest(pattern)
    end
  end

  defp short_digest(text),
    do: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower) |> binary_part(0, 12)

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
      title: "Fetch from #{repository(route)}",
      facts: [{"Repository", repository(route)}] ++ client(request),
      claims: [],
      pattern: "POST #{request.host}#{route}"
    }
  end

  defp refs(request, route, query) do
    service = URI.decode_query(query || "")["service"] || "git-upload-pack"

    %{
      title: "List refs of #{repository(route)}",
      facts: [{"Repository", repository(route)}, {"For", service}] ++ client(request),
      claims: [],
      pattern: "#{request.method} #{request.host}#{route}"
    }
  end

  # The type and the fields come from the operation a server would run
  # (`MDTClient.Sandbox.GraphQL`), not from the start of the text. Its name
  # is the author's, so "allow similar" goes by the whole document: the same
  # document with other variables is similar, another document with the
  # same name is not.
  defp graphql(request) do
    {label, fields, variables, digest} =
      case Jason.decode(request.body) do
        {:ok, %{"query" => document} = body} when is_binary(document) ->
          name = if is_binary(body["operationName"]), do: body["operationName"]
          variables = if is_map(body["variables"]), do: body["variables"], else: %{}

          case GraphQL.selected(document, name) do
            {:ok, operation} ->
              shown = operation.name || List.first(operation.fields)
              label = Enum.join(Enum.reject([operation.kind, shown], &is_nil/1), " ")
              {label, operation.fields, variables, GraphQL.digest(document)}

            :error ->
              {"unknown", [], variables, GraphQL.digest(document)}
          end

        _unreadable ->
          {"unknown", [], %{}, GraphQL.digest(request.body)}
      end

    fields = if fields == [], do: [], else: [{"Fields", Enum.join(fields, ", ")}]

    %{
      title: "GraphQL #{label} on #{request.host}",
      facts: [{"Operation", label}] ++ fields ++ repository_facts(variables) ++ client(request),
      claims: claims(variables),
      pattern: "POST #{request.host}/graphql · #{label} · #{digest}"
    }
  end

  defp rest(request, route) do
    body_claims =
      case Jason.decode(request.body) do
        {:ok, %{} = json} -> claims(json)
        _ -> []
      end

    %{
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
         <<line::binary-size(^length - 4), rest::binary>> <- rest,
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
