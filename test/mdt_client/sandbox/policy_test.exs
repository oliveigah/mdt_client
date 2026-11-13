defmodule MDTClient.Sandbox.PolicyTest do
  @moduledoc """
  The rules of `MDTClient.Sandbox.Policy`, checked for every combination of
  a small world: each state a grant can be in, each set of allowances on
  it, each host and address, each way a placeholder travels. A test here is
  a sentence that must hold for all of them, so a failure prints the one
  combination that breaks it.
  """
  use ExUnit.Case, async: true

  alias MDTClient.Sandbox.{Allowance, Describe, Grant, Policy}

  doctest MDTClient.Sandbox.Placeholder

  @now ~U[2026-11-13 12:00:00Z]
  @earlier ~U[2026-11-13 11:00:00Z]
  @later ~U[2026-11-13 13:00:00Z]

  @placeholder "mdt_ghp_0123456789abcdef0123456789abcdef"
  @other_placeholder "mdt_hex_fedcba9876543210fedcba9876543210"

  # Every state a grant can be in, with whether it is on at @now.
  @states [
    {:off, nil, false},
    {:off, @later, false},
    {:on, nil, true},
    {:on, @later, true},
    {:on, @earlier, false},
    {:on, @now, false}
  ]

  defp snapshot(grants, opts \\ []) do
    %{
      grants: grants,
      own: Keyword.get(opts, :own, [{192, 168, 1, 5}]),
      resolve:
        Keyword.get(opts, :resolve, fn
          "db.internal" -> [{10, 1, 2, 3}]
          "localhost" -> [{127, 0, 0, 1}]
          _other -> []
        end)
    }
  end

  defp subsets([]), do: [[]]

  defp subsets([first | rest]),
    do:
      for(
        set <- subsets(rest),
        with? <- [false, true],
        do: if(with?, do: [first | set], else: set)
      )

  defp allowance(pattern, until),
    do: %Allowance{
      id: "allowance-#{:erlang.phash2({pattern, until})}",
      pattern: pattern,
      until: until
    }

  # Whether some allowance of `allowances` covers `pattern` at `now`, said
  # again here in the plainest way.
  defp covered?(allowances, pattern, now) do
    Enum.any?(allowances, fn %Allowance{pattern: covers, until: until} ->
      (covers == :all or covers == pattern) and
        (is_nil(until) or DateTime.compare(now, until) == :lt)
    end)
  end

  defp kind(:pass), do: :pass
  defp kind({:allow, _grant, _allowance, _about}), do: :allow
  defp kind({:ask, _grant, _about}), do: :ask
  defp kind({:refuse, reason}) when is_tuple(reason), do: {:refuse, elem(reason, 0)}
  defp kind({:refuse, reason}), do: {:refuse, reason}

  ## Requests

  @listed [["api.example.com"], ["*.example.com"], ["API.Example.com"]]
  @hosts ~w(api.example.com example.com deep.api.example.com API.EXAMPLE.COM evil.test example.com.evil.test notexample.com)
  @carriers [:none, :bearer, :basic, :other_header, :two]
  @calls [{"GET", "/repos/a/b"}, {"POST", "/graphql"}]

  defp token_grant(state, expires_at, hosts, allowances) do
    %Grant{
      id: "github",
      name: "GitHub",
      kind: :token,
      state: state,
      expires_at: expires_at,
      placeholder: @placeholder,
      hosts: hosts,
      allowances: allowances
    }
  end

  defp other_token_grant do
    %Grant{
      id: "hex",
      name: "Hex",
      kind: :token,
      state: :on,
      placeholder: @other_placeholder,
      hosts: ["hex.pm", "*.example.com"],
      allowances: [allowance(:all, nil)]
    }
  end

  defp request(host, {method, path}, carrier) do
    headers =
      case carrier do
        :none -> [{"accept", "*/*"}]
        :bearer -> [{"authorization", "Bearer " <> @placeholder}]
        :basic -> [{"authorization", "Basic " <> Base.encode64("git:" <> @placeholder)}]
        :other_header -> [{"x-api-key", @placeholder}]
        :two -> [{"authorization", "Bearer " <> @placeholder}, {"x-other", @other_placeholder}]
      end

    body = if path == "/graphql", do: ~s({"query":"query { viewer { login } }"}), else: ""
    %{host: host, method: method, path: path, headers: headers, body: body}
  end

  defp host_listed?(host, hosts) do
    host = String.downcase(host)

    Enum.any?(hosts, fn entry ->
      entry = String.downcase(entry)

      case entry do
        "*." <> suffix -> host == suffix or String.ends_with?(host, "." <> suffix)
        exact -> host == exact
      end
    end)
  end

  # Every request the world holds, with the grant it meets.
  defp request_cases do
    for {state, expires_at, on?} <- @states,
        hosts <- @listed,
        host <- @hosts,
        call <- @calls,
        carrier <- @carriers do
      request = request(host, call, carrier)
      pattern = Describe.request(request).pattern

      allowance_sets =
        subsets([
          allowance(:all, nil),
          allowance(:all, @earlier),
          allowance(pattern, @later),
          allowance(pattern, @earlier),
          allowance("GET api.example.com/something/else", nil)
        ])

      for allowances <- allowance_sets do
        %{
          grant: token_grant(state, expires_at, hosts, allowances),
          on?: on?,
          listed?: host_listed?(host, hosts),
          carrier: carrier,
          request: request,
          pattern: pattern
        }
      end
    end
    |> List.flatten()
  end

  defp decide_request(one, now \\ @now, more \\ []) do
    Policy.decide(snapshot([one.grant, other_token_grant() | more]), {:request, one.request}, now)
  end

  describe "a request" do
    test "gets the one answer the rules give, in every combination" do
      cases = request_cases()
      assert length(cases) > 20_000

      for one <- cases do
        expected =
          cond do
            one.carrier == :none -> :pass
            one.carrier == :two -> {:refuse, :multiple_grants}
            not one.listed? -> {:refuse, :wrong_host}
            not one.on? -> {:refuse, :grant_off}
            covered?(one.grant.allowances, one.pattern, @now) -> :allow
            true -> :ask
          end

        assert kind(decide_request(one)) == expected, "wrong answer for #{inspect(one)}"
      end
    end

    test "with a placeholder never goes to a host its grant doesn't list" do
      for one <- request_cases(), one.carrier != :none, not one.listed? do
        assert match?({:refuse, _}, decide_request(one)), inspect(one)
      end
    end

    test "is let through or asked about only while its grant is on by the clock" do
      for one <- request_cases(), one.carrier != :none, not one.on? do
        assert match?({:refuse, _}, decide_request(one)), inspect(one)
      end
    end

    test "is allowed only by an allowance of its grant that is in time and covers it" do
      for one <- request_cases() do
        case decide_request(one) do
          {:allow, grant, allowance, about} ->
            assert grant == one.grant
            assert allowance in one.grant.allowances
            assert allowance.pattern in [:all, about.pattern]
            assert is_nil(allowance.until) or DateTime.compare(@now, allowance.until) == :lt

          _other ->
            :ok
        end
      end
    end

    test "that isn't allowed now isn't allowed later either: time only takes away" do
      for one <- request_cases(), kind(decide_request(one)) != :allow do
        for later <- [@later, DateTime.add(@later, 400, :day)] do
          refute kind(decide_request(one, later)) == :allow, inspect(one)
        end
      end
    end

    test "with no placeholder passes whatever the grants are" do
      for one <- request_cases(), one.carrier == :none do
        assert decide_request(one) == :pass
      end
    end

    test "gets the same answer whatever grants of other types exist" do
      others = [
        %Grant{
          id: "lan",
          name: "GitHub",
          kind: :network,
          state: :on,
          destinations: ["0.0.0.0/0"]
        },
        %Grant{id: "kube", name: "kube", kind: :file, state: :on, path: "kubeconfig"},
        %Grant{
          id: "shell",
          name: "shell",
          kind: :command,
          state: :on,
          allowances: [allowance(:all, nil)]
        }
      ]

      for one <- Enum.take_every(request_cases(), 7) do
        assert kind(decide_request(one, @now, others)) == kind(decide_request(one))
      end
    end
  end

  ## Connections

  @public [{93, 184, 216, 34}, {0x2606, 0x2800, 0x220, 1, 0x248, 0x1893, 0x25C8, 0x1946}]
  @private [{10, 1, 2, 3}, {172, 16, 9, 9}, {100, 64, 0, 1}, {0xFD00, 0, 0, 0, 0, 0, 0, 5}]
  # Loopback, link-local (cloud metadata), unspecified, an address of this
  # machine in a private range, and loopback written as IPv4-in-IPv6.
  @reserved [
    {127, 0, 0, 1},
    {169, 254, 169, 254},
    {0, 0, 0, 0},
    {0, 0, 0, 0, 0, 0, 0, 1},
    {192, 168, 1, 5},
    {0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 1}
  ]
  @ports [443, 5432]
  @destinations [
    [],
    ["10.0.0.0/8"],
    ["10.1.2.3"],
    ["10.1.2.3:5432"],
    ["127.0.0.1:5432"],
    ["127.0.0.0/8"],
    ["0.0.0.0/0", "::/0"],
    ["192.168.0.0/16"],
    ["192.168.1.5"],
    ["169.254.169.254:443"],
    ["db.internal:5432"],
    ["localhost"],
    ["fd00::/8"],
    ["not a destination"]
  ]

  defp network_grant(state, expires_at, destinations, allowances) do
    %Grant{
      id: "lan",
      name: "LAN",
      kind: :network,
      state: state,
      expires_at: expires_at,
      destinations: destinations,
      allowances: allowances
    }
  end

  defp connection_cases(addresses) do
    for ip <- addresses,
        port <- @ports,
        {state, expires_at, on?} <- @states,
        destinations <- @destinations,
        allowances <-
          subsets([
            allowance(:all, nil),
            allowance("#{:inet.ntoa(ip)}:#{port}", @later),
            allowance("#{:inet.ntoa(ip)}:#{port}", @earlier)
          ]) do
      %{
        ip: ip,
        port: port,
        on?: on?,
        grant: network_grant(state, expires_at, destinations, allowances)
      }
    end
  end

  defp decide_connection(one, more \\ []) do
    Policy.decide(snapshot([one.grant | more]), {:connection, one.ip, one.port}, @now)
  end

  # The entries that name `ip` exactly, with a port that fits: said here as
  # text, apart from the parser.
  defp names_exactly?(destinations, ip, port) do
    address = "#{:inet.ntoa(ip)}"

    Enum.any?(destinations, fn entry ->
      entry == address or entry == "#{address}:#{port}"
    end)
  end

  describe "a connection" do
    test "to a public address passes, whatever the grants" do
      for one <- connection_cases(@public) do
        assert decide_connection(one) == :pass
      end
    end

    test "to this machine or a reserved range opens only for an entry naming that very address" do
      for one <- connection_cases(@reserved) do
        opened? = kind(decide_connection(one)) in [:allow, :ask]
        named? = one.on? and names_exactly?(one.grant.destinations, one.ip, one.port)

        assert opened? == named?,
               "#{:inet.ntoa(one.ip)}:#{one.port} with #{inspect(one.grant.destinations)}, on: #{one.on?}"

        unless opened?, do: assert(decide_connection(one) == {:refuse, :reserved})
      end
    end

    test "to a private range opens only while a network grant listing it is on" do
      for one <- connection_cases(@private) do
        case decide_connection(one) do
          {:refuse, reason} ->
            assert reason == :private

          answer ->
            assert kind(answer) in [:allow, :ask]
            assert one.on?, inspect(one)
            assert one.grant.destinations != []
        end
      end

      # The ranges and names of the world do open what they cover.
      opens = fn destinations, ip, port ->
        one = %{ip: ip, port: port, grant: network_grant(:on, nil, destinations, [])}
        kind(decide_connection(one))
      end

      assert opens.(["10.0.0.0/8"], {10, 1, 2, 3}, 443) == :ask
      assert opens.(["10.1.2.3:5432"], {10, 1, 2, 3}, 5432) == :ask
      assert opens.(["10.1.2.3:5432"], {10, 1, 2, 3}, 443) == {:refuse, :private}
      assert opens.(["db.internal:5432"], {10, 1, 2, 3}, 5432) == :ask
      assert opens.(["fd00::/8"], {0xFD00, 0, 0, 0, 0, 0, 0, 5}, 22) == :ask
      assert opens.(["192.168.0.0/16"], {172, 16, 9, 9}, 443) == {:refuse, :private}
    end

    test "is allowed only by an allowance for that address and port, in time" do
      for one <- connection_cases(@private ++ @reserved) do
        case decide_connection(one) do
          {:allow, grant, allowance, about} ->
            assert grant == one.grant
            assert about.pattern == "#{:inet.ntoa(one.ip)}:#{one.port}"
            assert covered?([allowance], about.pattern, @now)

          {:ask, _grant, about} ->
            refute covered?(one.grant.allowances, about.pattern, @now)

          _refused ->
            :ok
        end
      end
    end

    test "is never opened by a grant that isn't a network grant" do
      others =
        for kind <- [:token, :file, :command] do
          %Grant{
            id: "#{kind}",
            name: "#{kind}",
            kind: kind,
            state: :on,
            hosts: ["10.1.2.3"],
            destinations: ["0.0.0.0/0", "10.1.2.3", "127.0.0.1"],
            allowances: [allowance(:all, nil)]
          }
        end

      for ip <- @private ++ @reserved, port <- @ports do
        answer = Policy.decide(snapshot(others), {:connection, ip, port}, @now)
        assert match?({:refuse, _}, answer), "#{:inet.ntoa(ip)}:#{port}"
      end
    end
  end

  ## Commands

  defp command_grant(state, expires_at, script, allowances) do
    %Grant{
      id: "deploy",
      name: "Deploy",
      kind: :command,
      state: state,
      expires_at: expires_at,
      script: script,
      dir: script && "/srv/app",
      allowances: allowances
    }
  end

  defp command_cases do
    for {state, expires_at, on?} <- @states,
        script <- [nil, "make deploy"],
        allowances <- [[], [allowance(:all, nil)], [allowance("run abc", @later)]],
        named <- [nil, "", "deploy", "DEPLOY", " Deploy ", "nope", "github", 42, %{"a" => 1}],
        sent <- [nil, "", "   ", "rm -rf ~", 42] do
      %{
        grant: command_grant(state, expires_at, script, allowances),
        on?: on?,
        ask: %{grant: named, script: sent, reason: "because"}
      }
    end
  end

  describe "a command" do
    test "is never let through unasked, whatever allowances its grant carries" do
      for one <- command_cases() do
        answer = Policy.decide(snapshot([one.grant]), {:command, one.ask}, @now)
        # The compiler works this one out by itself: the clause for commands
        # has no way to answer anything else.
        assert elem(answer, 0) in [:ask, :refuse], inspect(one)
      end
    end

    test "is asked about only when the agent names a command grant that is on by the clock" do
      for one <- command_cases() do
        answer = Policy.decide(snapshot([one.grant]), {:command, one.ask}, @now)

        named? =
          is_binary(one.ask.grant) and String.downcase(String.trim(one.ask.grant)) == "deploy"

        if kind(answer) == :ask do
          assert named? and one.on?, inspect(one)
        end

        if named? and not one.on?, do: assert(kind(answer) == {:refuse, :grant_off})
      end
    end

    test "of a grant with your own script never takes text from the agent" do
      for one <- command_cases(), one.grant.script != nil do
        case Policy.decide(snapshot([one.grant]), {:command, one.ask}, @now) do
          {:ask, _grant, about} ->
            assert about == %{script: "make deploy", dir: "/srv/app"}
            refute is_binary(one.ask.script) and String.trim(one.ask.script) != ""

          {:refuse, _reason} ->
            :ok
        end
      end
    end

    test "runs nowhere when no command grant exists, whatever else does" do
      others = [
        token_grant(:on, nil, ["api.example.com"], [allowance(:all, nil)]),
        network_grant(:on, nil, ["0.0.0.0/0"], [allowance(:all, nil)]),
        %Grant{id: "deploy", name: "deploy", kind: :file, state: :on, path: "deploy"}
      ]

      for one <- command_cases() do
        assert Policy.decide(snapshot(others), {:command, one.ask}, @now) ==
                 {:refuse, :no_command_grant}
      end
    end
  end

  describe "which hosts are read" do
    test "every host a token grant lists, on or off, and no other" do
      for {state, expires_at, _on?} <- @states, hosts <- @listed, host <- @hosts do
        grants = [
          token_grant(state, expires_at, hosts, []),
          network_grant(:on, nil, ["evil.test"], [])
        ]

        assert Policy.reads?(grants, host) == host_listed?(host, hosts)
      end

      refute Policy.reads?([token_grant(:on, nil, ["api.example.com"], [])], nil)
    end
  end
end
