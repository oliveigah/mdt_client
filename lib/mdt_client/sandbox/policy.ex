defmodule MDTClient.Sandbox.Policy do
  @moduledoc """
  What MDT answers to one use the VM makes of a grant: a connection to an
  address, a request carrying a placeholder, a command for this machine.

  `decide/3` is pure. Its answer depends on the grants, the use and the clock
  it is given, and on nothing else: it holds nobody, logs nothing and never
  sees a real value. `MDTClient.Sandbox.Server` asks it and acts on the
  answer, so the rules are checked on their own, for every combination
  (`test/mdt_client/sandbox/policy_test.exs`).

  | Answer                              | The server then                                    |
  | ----------------------------------- | -------------------------------------------------- |
  | `:pass`                             | lets it through: no grant has a say                |
  | `{:allow, grant, allowance, about}` | lets it through, with the real value for a request |
  | `{:ask, grant, about}`              | holds it for you                                   |
  | `{:refuse, reason}`                 | refuses it, and says why                           |

  The rules, in the order they are tried:

    * **A connection** to a public address passes. One to this machine or a
      reserved range needs a network grant that is on and names that exact
      address; one to a private range needs a network grant that is on and
      lists it. Then an allowance for that address and port lets it through,
      or it asks.
    * **A request** with no placeholder in its headers passes. With two
      grants' placeholders it is refused. With one, the host must be on that
      grant's list and the grant must be on; then an allowance for uses like
      it lets it through, or it asks.
    * **A command** needs a command grant, named by the agent, that is on.
      One with a script of yours takes no text from the agent. It always
      asks: no allowance covers a command.
  """

  alias MDTClient.Sandbox.{Allowance, Describe, Destinations, Grant, Placeholder}

  @typedoc """
  What a decision reads: the grants, this machine's own addresses, and how a
  host name in a network grant resolves here.
  """
  @type snapshot :: %{
          grants: [Grant.t()],
          own: [Destinations.ip()],
          resolve: (String.t() -> [Destinations.ip()])
        }

  @type use ::
          {:connection, Destinations.ip(), :inet.port_number()}
          | {:request, Describe.request()}
          | {:command, map()}

  @type refusal ::
          :reserved
          | :private
          | :multiple_grants
          | {:wrong_host, Grant.t()}
          | {:grant_off, Grant.t()}
          | :no_command_grant
          | {:name_a_grant, [String.t()]}
          | {:no_such_grant, [String.t()]}
          | {:fixed_script, Grant.t()}

  @type answer ::
          :pass
          | {:allow, Grant.t(), Allowance.t(), map()}
          | {:ask, Grant.t(), map()}
          | {:refuse, refusal()}

  @doc "The snapshot of these grants on this machine, as it is now."
  @spec snapshot([Grant.t()]) :: snapshot()
  def snapshot(grants) do
    %{grants: grants, own: Destinations.host_addresses(), resolve: &Destinations.resolve/1}
  end

  @doc """
  Decides one use at `now`.

  `about` is what an approval shows and what an allowance is matched on. For
  a connection: `pattern` (`address:port`) and `listed_as`, the grant's entry
  that covers it. For a request: `MDTClient.Sandbox.Describe.request/1`. For
  a command: the grant's `script` and `dir`, both nil when the agent sends
  the text.
  """
  @spec decide(snapshot(), use(), DateTime.t()) :: answer()
  def decide(%{grants: grants} = snapshot, {:connection, ip, port}, now) do
    case Destinations.classify(ip, snapshot.own) do
      :public ->
        :pass

      class ->
        opening =
          Enum.find_value(grants, fn
            %Grant{kind: :network} = grant ->
              if Grant.on?(grant, now) do
                spec = Enum.find(specs(grant), &opens?(&1, class, ip, port, snapshot.resolve))
                spec && {grant, spec}
              end

            _other ->
              nil
          end)

        case opening do
          nil ->
            {:refuse, if(class == :refused, do: :reserved, else: :private)}

          {grant, spec} ->
            pattern = "#{:inet.ntoa(ip)}:#{port}"
            allow_or_ask(grant, now, %{pattern: pattern, listed_as: spec.source})
        end
    end
  end

  def decide(%{grants: grants}, {:request, request}, now) do
    carried =
      for %Grant{kind: :token} = grant <- grants,
          Placeholder.in?(request.headers, grant.placeholder),
          do: grant

    case carried do
      [] ->
        :pass

      [_, _ | _] ->
        {:refuse, :multiple_grants}

      [grant] ->
        cond do
          not host_listed?(request.host, grant.hosts) -> {:refuse, {:wrong_host, grant}}
          not Grant.on?(grant, now) -> {:refuse, {:grant_off, grant}}
          true -> allow_or_ask(grant, now, Describe.request(request))
        end
    end
  end

  def decide(%{grants: grants}, {:command, ask}, now) do
    commands = Enum.filter(grants, &(&1.kind == :command))
    ids = Enum.map(commands, & &1.id)
    wanted = ask |> Map.get(:grant) |> text() |> String.trim()

    grant =
      Enum.find(commands, fn grant ->
        grant.id == wanted or String.downcase(grant.name) == String.downcase(wanted)
      end)

    cond do
      commands == [] ->
        {:refuse, :no_command_grant}

      wanted == "" ->
        {:refuse, {:name_a_grant, ids}}

      is_nil(grant) ->
        {:refuse, {:no_such_grant, ids}}

      not Grant.on?(grant, now) ->
        {:refuse, {:grant_off, grant}}

      is_nil(grant.script) ->
        {:ask, grant, %{script: nil, dir: nil}}

      ask |> Map.get(:script) |> text() |> String.trim() != "" ->
        {:refuse, {:fixed_script, grant}}

      true ->
        {:ask, grant, %{script: grant.script, dir: grant.dir}}
    end
  end

  @doc """
  Whether connections to `host` are read instead of tunnelled: some token
  grant lists it, on or off. An off grant's host is still read, so its
  placeholder is refused with a reason instead of going out as it is.
  """
  @spec reads?([Grant.t()], String.t() | nil) :: boolean()
  def reads?(grants, host),
    do: Enum.any?(grants, &(&1.kind == :token and host_listed?(host, &1.hosts)))

  @doc """
  Whether `host` is on a token grant's list. `*.example.com` covers
  `example.com` and every name under it; any other entry covers itself.
  """
  @spec host_listed?(String.t() | nil, [String.t()]) :: boolean()
  def host_listed?(host, hosts) do
    host = String.downcase(host || "")

    Enum.any?(hosts, fn
      "*." <> suffix -> host == suffix or String.ends_with?(host, "." <> suffix)
      exact -> host == String.downcase(exact)
    end)
  end

  # A reserved address opens only for an entry that names it exactly; a
  # private one for any entry that covers it.
  defp opens?(spec, class, ip, port, resolve) do
    Destinations.matches?(spec, ip, port, resolve) and
      (class == :private or Destinations.exact?(spec, ip))
  end

  defp allow_or_ask(grant, now, about) do
    case Enum.find(grant.allowances, &Allowance.covers?(&1, about.pattern, now)) do
      nil -> {:ask, grant, about}
      allowance -> {:allow, grant, allowance, about}
    end
  end

  defp specs(%Grant{destinations: destinations}) do
    case Destinations.parse_all(destinations) do
      {:ok, specs} -> specs
      {:error, _} -> []
    end
  end

  defp text(value) when is_binary(value), do: value
  defp text(_other), do: ""
end
