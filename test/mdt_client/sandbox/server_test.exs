defmodule MDTClient.Sandbox.ServerTest do
  use ExUnit.Case, async: true

  alias MDTClient.Sandbox
  alias MDTClient.Sandbox.Server
  alias MDTClient.Vault.Store

  setup do
    MDTClient.VaultHelpers.unlocked_identity("sandbox")
  end

  @github %{
    "kind" => "token",
    "preset" => "github",
    "name" => "GitHub",
    "purpose" => "Push to oliveigah/klife",
    "hosts" => "api.github.com, github.com, uploads.github.com",
    "env" => "GITHUB_TOKEN, GH_TOKEN",
    "git" => "true",
    "prefix" => "ghp_",
    "source" => "stored"
  }

  # On, and by default letting every use through, so tests about swapping
  # don't wait; `uses: :ask` is the default for real grants.
  defp github(username, uses \\ :all) do
    {:ok, grant} =
      Sandbox.create_grant(username, Map.put(@github, "value", "ghp_real_value"))

    {:ok, grant} = Sandbox.turn_on(username, grant.id, 60, uses)
    grant
  end

  defp request(grant, attrs \\ %{}) do
    Map.merge(
      %{
        host: "api.github.com",
        method: "GET",
        path: "/user",
        headers: [{"authorization", "token #{grant.placeholder}"}, {"user-agent", "gh"}],
        body: ""
      },
      attrs
    )
  end

  defp authorize(username, request), do: Server.call(username, {:authorize, request})

  defp authorize_async(username, request),
    do: Task.async(fn -> Server.call(username, {:authorize, request}, :infinity) end)

  defp wait_for_approval(username) do
    Enum.find_value(1..100, fn _ ->
      case Sandbox.snapshot(username).waiting do
        [approval | _] -> approval
        [] -> Process.sleep(10) && nil
      end
    end)
  end

  test "a new identity starts empty, with a CA and a default Containerfile", %{username: username} do
    snapshot = Sandbox.snapshot(username)
    assert snapshot.grants == []
    assert snapshot.settings.containerfile =~ "FROM "
    assert snapshot.settings.image_name == "mdt_agent_sdb_image"
    assert snapshot.image.tag == nil
    assert snapshot.builds == []
    assert snapshot.snapshots == []
    assert Sandbox.ca_pem(username) =~ "BEGIN CERTIFICATE"
    assert File.read!(Path.join(snapshot.inbox, "ca.pem")) == Sandbox.ca_pem(username)
  end

  test "the image name must be one OCI accepts", %{username: username} do
    assert {:error, %{image_name: _}} =
             Sandbox.update_settings(username, %{"image_name" => "My Box"})

    assert {:ok, settings} = Sandbox.update_settings(username, %{"image_name" => " my_box "})
    assert settings.image_name == "my_box"
  end

  test "only kept builds can be made current", %{username: username} do
    assert Sandbox.use_build(username, "mdt_agent_sdb_image:2026-11-12.1") == {:error, :not_found}
  end

  test "a VM created before the explicit Bash shell needs recreation", %{username: username} do
    pid = GenServer.whereis(Store.via(Server, username))

    :sys.replace_state(pid, fn state ->
      previous_spec = %{
        name: state.vm.name,
        image: "box:1",
        cpus: state.settings.cpus,
        memory_gib: state.settings.memory_gib,
        proxy_port: state.settings.proxy_port,
        mounts: [
          {Path.join(state.dir, "inbox"), "/mnt/mdt", :ro},
          {state.folders.home, "/root", :rw},
          {state.folders.optmem, "/root/.optmem", :rw},
          {state.folders.cache, "/cache", :rw}
        ]
      }

      %{
        state
        | vm: %{state.vm | exists?: true},
          image: %{state.image | tag: "box:1"},
          created_spec: :erlang.phash2(previous_spec)
      }
    end)

    assert Sandbox.snapshot(username).vm.stale?
  end

  test "creating checks the choices before touching anything", %{username: username} do
    assert Sandbox.recreate_vm(username) == {:error, :no_image}

    pid = GenServer.whereis(Store.via(Server, username))

    :sys.replace_state(pid, fn state ->
      %{state | image: %{state.image | loaded?: true, tag: "box:2026-11-12.1"}}
    end)

    assert Sandbox.recreate_vm(username, %{home: {:snapshot, "gone"}}) == {:error, :no_snapshot}
    assert Sandbox.recreate_vm(username, %{cache: :burn}) == {:error, :bad_options}
    assert Sandbox.snapshot(username).vm.busy == nil
  end

  test "the VM's memories are reviewed from where the last review ended", %{username: username} do
    snapshot = Sandbox.snapshot(username)
    memory = Path.join(snapshot.folders.optmem, "memory")
    File.mkdir_p!(memory)

    log =
      for {text, id} <- Enum.with_index(["one", "two", "three"]),
          do: String.pad_trailing("##{id} 2026-11-12 #{text}", 319) <> "\n"

    File.write!(Path.join(memory, "LOG.txt"), Enum.join(log))

    assert %{entries: [_, _, _], upto: 3} = Sandbox.vm_memories(username)
    assert :ok = Sandbox.dismiss_memories(username, 2)
    assert %{entries: [%{text: "three"}], upto: 3} = Sandbox.vm_memories(username)
    assert Sandbox.snapshot(username).memory.reviewed == 2
  end

  test "grants check what each type needs, and values never leave the server", %{
    username: username
  } do
    assert {:error, %{kind: _}} = Sandbox.create_grant(username, %{"name" => "x"})

    assert {:error, errors} = Sandbox.create_grant(username, %{"kind" => "token", "name" => ""})
    assert Map.keys(errors) |> Enum.sort() == [:hosts, :name, :purpose, :value]

    assert {:error, %{env: _, hosts: _, prefix: _}} =
             Sandbox.create_grant(
               username,
               Map.merge(@github, %{
                 "env" => "BAD-NAME",
                 "hosts" => "https://x.com",
                 "prefix" => "a b",
                 "value" => "v"
               })
             )

    assert {:error, %{destinations: _}} =
             Sandbox.create_grant(username, %{
               "kind" => "network",
               "name" => "VPN",
               "purpose" => "Grafana",
               "destinations" => "10.0.0.0/99"
             })

    grant = github(username)
    assert String.starts_with?(grant.placeholder, "ghp_")
    assert grant.preset == :github and grant.git
    refute inspect(Sandbox.snapshot(username)) =~ "ghp_real_value"
    assert Sandbox.snapshot(username).values[grant.id]
  end

  test "every use waits by default; requests without a placeholder pass untouched",
       %{username: username} do
    grant = github(username, :ask)

    plain = %{request(grant) | headers: [{"accept", "*/*"}]}
    assert {:forward, [{"accept", "*/*"}], []} = authorize(username, plain)

    read = authorize_async(username, request(grant))
    approval = wait_for_approval(username)
    assert approval.kind == :request
    assert approval.request.headers == request(grant).headers
    :ok = Sandbox.decide(username, approval.id, :allow_once)

    assert {:forward, headers, [{"ghp_real_value", placeholder}]} = Task.await(read)
    assert {"authorization", "token ghp_real_value"} in headers
    assert placeholder == grant.placeholder
  end

  test "Basic credentials are swapped inside, as git sends them", %{username: username} do
    grant = github(username)
    basic = "Basic " <> Base.encode64("x-access-token:#{grant.placeholder}")

    assert {:forward, [{"authorization", swapped}], _} =
             authorize(
               username,
               request(grant, %{headers: [{"authorization", basic}], path: "/o/r.git/info/refs"})
             )

    assert swapped == "Basic " <> Base.encode64("x-access-token:ghp_real_value")
  end

  test "a placeholder sent to another host is blocked and logged", %{username: username} do
    grant = github(username)

    assert {:deny, 403, body} = authorize(username, request(grant, %{host: "paste.example.net"}))
    assert body =~ "mdt_placeholder_blocked"
    assert [%{outcome: :violation} | _] = Sandbox.events(username)
  end

  test "an off grant refuses with a reason the agent can read", %{username: username} do
    grant = github(username)
    {:ok, _} = Sandbox.turn_off(username, grant.id)

    assert {:deny, 403, body} = authorize(username, request(grant))

    assert %{"code" => "mdt_grant_off", "grant" => "GitHub", "error" => error} =
             Jason.decode!(body)

    assert error =~ "mdt request #{grant.id}"
  end

  test "a push waits for you; retries join it; allowing answers all of them", %{
    username: username
  } do
    grant = github(username, :ask)

    push =
      request(grant, %{host: "github.com", method: "POST", path: "/o/r.git/git-receive-pack"})

    first = authorize_async(username, push)
    approval = wait_for_approval(username)
    retry = authorize_async(username, push)

    Enum.find_value(1..100, fn _ ->
      if hd(Sandbox.snapshot(username).waiting).retries == 1,
        do: true,
        else: Process.sleep(10) && nil
    end)

    assert Sandbox.waiting_count(username) == 1
    :ok = Sandbox.decide(username, approval.id, :allow_once)

    assert {:forward, headers, _} = Task.await(first)
    assert {:forward, ^headers, _} = Task.await(retry)
    assert {"authorization", "token ghp_real_value"} in headers
    assert Sandbox.waiting_count(username) == 0
  end

  test "denying, allowing similar, and giving up", %{username: username} do
    grant = github(username, :ask)

    push =
      request(grant, %{host: "github.com", method: "POST", path: "/o/r.git/git-receive-pack"})

    denied = authorize_async(username, push)
    :ok = Sandbox.decide(username, wait_for_approval(username).id, :deny)
    assert {:deny, 403, body} = Task.await(denied)
    assert body =~ "mdt_denied_by_user"

    similar = authorize_async(username, push)
    :ok = Sandbox.decide(username, wait_for_approval(username).id, {:allow, :similar, 10})
    assert {:forward, _, _} = Task.await(similar)
    assert {:forward, _, _} = authorize(username, push)

    other =
      request(grant, %{host: "github.com", method: "POST", path: "/o/other.git/git-receive-pack"})

    late = authorize_async(username, other)
    approval = wait_for_approval(username)
    send(Store.whereis(Server, username), {:give_up, approval.id})
    assert {:deny, 403, body} = Task.await(late)
    assert body =~ "mdt_approval_timeout"
  end

  test "allowing every use lets the waiting ones through, and ends when the grant turns off",
       %{username: username} do
    grant = github(username, :ask)
    push = request(grant, %{method: "POST", path: "/repos/o/r/pulls"})
    read = request(grant, %{path: "/user"})

    held_push = authorize_async(username, push)
    approval = wait_for_approval(username)
    held_read = authorize_async(username, read)

    Enum.find_value(1..100, fn _ ->
      if length(Sandbox.snapshot(username).waiting) == 2, do: true, else: Process.sleep(10) && nil
    end)

    assert Sandbox.decide(username, approval.id, {:turn_on, 10, :ask}) ==
             {:error, :bad_decision}

    :ok = Sandbox.decide(username, approval.id, {:allow, :all, :grant})
    assert {:forward, _, _} = Task.await(held_push)
    assert {:forward, _, _} = Task.await(held_read)
    assert {:forward, _, _} = authorize(username, request(grant, %{path: "/anything"}))

    {:ok, _} = Sandbox.turn_off(username, grant.id)
    assert {:error, :off} = Sandbox.allow_all(username, grant.id, 10)
    assert {:error, :not_found} = Sandbox.allow_all(username, "nope", 10)
    {:ok, grant} = Sandbox.turn_on(username, grant.id, 60)
    assert grant.allowances == []

    {:ok, grant} = Sandbox.allow_all(username, grant.id, 10)
    assert [%{pattern: :all, until: %DateTime{}}] = grant.allowances
    assert {:forward, _, _} = authorize(username, push)
  end

  test "minted values come from the command, and are reused", %{username: username} do
    {:ok, grant} =
      Sandbox.create_grant(username, %{
        "kind" => "token",
        "name" => "Google",
        "purpose" => "gcloud",
        "hosts" => "*.googleapis.com",
        "file_env" => "CLOUDSDK_AUTH_ACCESS_TOKEN_FILE",
        "source" => "minted",
        "mint" => "echo ya29.minted-$((40 + 2))"
      })

    {:ok, grant} = Sandbox.turn_on(username, grant.id, 60, :all)

    google = %{
      host: "storage.googleapis.com",
      method: "GET",
      path: "/storage/v1/b",
      headers: [{"authorization", "Bearer #{grant.placeholder}"}],
      body: ""
    }

    assert {:forward, [{"authorization", "Bearer ya29.minted-42"}], _} =
             authorize(username, google)

    assert {:forward, [{"authorization", "Bearer ya29.minted-42"}], _} =
             authorize(username, google)
  end

  test "destinations: public passes, private needs a grant, refused needs an exact one",
       %{username: username} do
    destination = fn ip, port -> Server.call(username, {:destination, ip, port}) end

    assert destination.({140, 82, 112, 3}, 443) == :ok
    assert {:deny, _} = destination.({10, 20, 4, 12}, 5432)
    assert {:deny, _} = destination.({127, 0, 0, 1}, 5433)

    {:ok, tunnel} =
      Sandbox.create_grant(username, %{
        "kind" => "network",
        "preset" => "database",
        "name" => "Tunnel",
        "purpose" => "The database",
        "destinations" => "127.0.0.1:5433\n10.20.0.0/16:5432"
      })

    {:ok, _} = Sandbox.turn_on(username, tunnel.id, 60)

    held =
      Task.async(fn ->
        Server.call(username, {:destination, {10, 20, 4, 12}, 5432}, :infinity)
      end)

    approval = wait_for_approval(username)
    assert approval.kind == :connection
    assert {"Listed as", "10.20.0.0/16:5432"} in approval.facts
    :ok = Sandbox.decide(username, approval.id, :allow_once)
    assert Task.await(held) == :ok

    {:ok, _} = Sandbox.allow_all(username, tunnel.id, :grant)
    assert destination.({127, 0, 0, 1}, 5433) == :ok
    assert {:deny, _} = destination.({127, 0, 0, 1}, 4000)
    assert destination.({10, 20, 4, 12}, 5432) == :ok
  end

  ## Agents asking

  defp ask(username, attrs),
    do:
      Server.call(
        username,
        {:request_access, Map.merge(%{reason: "push the fix", agent: "claude"}, attrs)}
      )

  defp await(username, id, ms \\ 5_000),
    do: Task.async(fn -> Server.call(username, {:await, id, ms}, ms + 1_000) end)

  test "an agent's ask waits as an activation; turning it on answers the agent", %{
    username: username
  } do
    {:ok, grant} = Sandbox.create_grant(username, Map.put(@github, "value", "ghp_real_value"))

    assert {:error, :unknown_grant} = ask(username, %{grant: "gitlab"})
    assert {:error, :no_reason} = ask(username, %{grant: grant.id, reason: " "})
    assert {:error, :bad_minutes} = ask(username, %{grant: grant.id, minutes: 0})
    assert {:error, :nothing_asked} = ask(username, %{})

    assert {:ok, %{kind: :activation, minutes: 30} = approval} =
             ask(username, %{grant: "github", minutes: 30})

    # By name too, and asking again joins the same card.
    assert {:ok, %{id: same, retries: 1}} = ask(username, %{grant: "GITHUB", minutes: 30})
    assert same == approval.id
    assert Sandbox.waiting_count(username) == 1

    waiting = await(username, approval.id)
    Process.sleep(20)

    assert Sandbox.decide(username, approval.id, :allow_once) == {:error, :bad_decision}
    :ok = Sandbox.decide(username, approval.id, {:turn_on, 15, :ask})

    assert {:ok, %{status: :allowed, decision: {:turn_on, 15, :ask}}, %{state: :on} = on} =
             Task.await(waiting)

    assert DateTime.diff(on.expires_at, DateTime.utc_now()) in 880..900
    assert on.allowances == []
    assert {:already_on, _} = ask(username, %{grant: grant.id})
    assert [%{summary: summary} | _] = Sandbox.events(username)
    assert summary =~ "asked by claude"
  end

  test "an agent that stops waiting hears pending; the ask stays; allow-all comes with it",
       %{username: username} do
    {:ok, grant} = Sandbox.create_grant(username, Map.put(@github, "value", "ghp_real_value"))
    {:ok, approval} = ask(username, %{grant: grant.id})

    assert Task.await(await(username, approval.id, 30)) == :pending
    assert [%{status: :waiting}] = Sandbox.snapshot(username).waiting

    waiting = await(username, approval.id)
    Process.sleep(20)
    :ok = Sandbox.decide(username, approval.id, {:turn_on, :until_off, :all})
    assert {:ok, _, %{expires_at: nil, allowances: [%{pattern: :all}]}} = Task.await(waiting)

    # A settled ask answers at once.
    assert {:ok, %{status: :allowed}, _} = Task.await(await(username, approval.id))
    assert {:error, :not_found} = Task.await(await(username, "ask-nope"))
  end

  test "declining, giving up, turning on yourself, and removing the grant answer the agent", %{
    username: username
  } do
    {:ok, grant} = Sandbox.create_grant(username, Map.put(@github, "value", "ghp_real_value"))

    {:ok, declined} = ask(username, %{grant: grant.id})
    waiting = await(username, declined.id)
    Process.sleep(20)
    :ok = Sandbox.decide(username, declined.id, :decline)
    assert {:ok, %{status: :denied, decision: :decline}, _} = Task.await(waiting)

    {:ok, late} = ask(username, %{grant: grant.id})
    send(Store.whereis(Server, username), {:give_up, late.id})
    assert {:ok, %{status: :timed_out}, _} = Task.await(await(username, late.id))

    {:ok, mine} = ask(username, %{grant: grant.id})
    waiting = await(username, mine.id)
    Process.sleep(20)
    {:ok, _} = Sandbox.turn_on(username, grant.id, 60)
    assert {:ok, %{status: :allowed}, %{state: :on}} = Task.await(waiting)

    {:ok, _} = Sandbox.turn_off(username, grant.id)
    {:ok, gone} = ask(username, %{grant: grant.id})
    :ok = Sandbox.delete_grant(username, grant.id)

    assert {:ok, %{status: :denied, decision: :grant_off}, nil} =
             Task.await(await(username, gone.id))
  end

  test "an ask for something new is answered by setting a grant up", %{username: username} do
    {:ok, approval} =
      ask(username, %{need: "Read access to the staging Postgres at 10.1.2.3:5432", minutes: 45})

    assert approval.grant_id == nil and approval.title == "Access you haven't set up"
    assert Sandbox.decide(username, approval.id, {:set_up, "nope"}) == {:error, :bad_decision}

    {:ok, grant} =
      Sandbox.create_grant(username, %{
        "kind" => "network",
        "name" => "Staging DB",
        "purpose" => "Staging Postgres",
        "destinations" => "10.1.2.3:5432"
      })

    waiting = await(username, approval.id)
    Process.sleep(20)
    :ok = Sandbox.decide(username, approval.id, {:set_up, grant.id})
    assert {:ok, %{status: :allowed}, %{id: id, state: :on} = on} = Task.await(waiting)
    assert id == grant.id
    assert DateTime.diff(on.expires_at, DateTime.utc_now()) in 2680..2700
  end

  test "agents can't flood you: ten asks wait at most", %{username: username} do
    for n <- 1..10, do: assert({:ok, _} = ask(username, %{need: "thing #{n}"}))
    assert {:error, :too_many} = ask(username, %{need: "one more"})
    assert {:ok, %{retries: 1}} = ask(username, %{need: "thing 3"})
  end

  test "grants saved before types and presets are brought up to date" do
    old = %{
      __struct__: MDTClient.Sandbox.Grant,
      id: "google",
      name: "Google",
      recipe: :google,
      kind: :http,
      placeholder: "ya29.mdtx",
      env: ["CLOUDSDK_AUTH_ACCESS_TOKEN_FILE"],
      hosts: ["*.googleapis.com"],
      rules: [:whatever],
      default_action: :ask,
      per_connection: :allow,
      allowances: [
        %{__struct__: MDTClient.Sandbox.Allowance, id: "a", pattern: "GET x", until: nil}
      ],
      source: {:minted, "gcloud auth print-access-token"},
      state: :on
    }

    upgraded = MDTClient.Sandbox.Grant.upgrade(old)
    assert %MDTClient.Sandbox.Grant{kind: :token, preset: :google, env: []} = upgraded
    assert upgraded.file_env == ["CLOUDSDK_AUTH_ACCESS_TOKEN_FILE"]
    assert upgraded.purpose =~ "Google Cloud"
    refute Map.has_key?(upgraded, :rules)
    assert [%MDTClient.Sandbox.Allowance{pattern: "GET x"}] = upgraded.allowances

    github = MDTClient.Sandbox.Grant.upgrade(%{old | recipe: :github, env: ["GH_TOKEN"]})
    assert github.git and github.env == ["GH_TOKEN"] and github.preset == :github
  end

  test "grants and values survive locking", %{username: username, key: key} do
    grant = github(username)
    :ok = Store.close(username)
    :ok = Store.open(username, key)

    assert [%{id: id, placeholder: placeholder}] = Sandbox.snapshot(username).grants
    assert id == grant.id and placeholder == grant.placeholder
    {:ok, grant} = Sandbox.turn_on(username, grant.id, 60)
    assert {:forward, _, [{"ghp_real_value", _}]} = authorize(username, request(grant))
  end

  test "crash reports and status dumps never carry values or keys", %{username: username} do
    github(username)
    status = :sys.get_status(Store.whereis(Server, username))

    refute inspect(status, limit: :infinity, printable_limit: :infinity) =~ "ghp_real_value"
    assert inspect(status, limit: :infinity) =~ ":redacted"
  end

  test "the inbox holds placeholders and git's answers, never stored values", %{
    username: username
  } do
    grant = github(username)
    inbox = Sandbox.snapshot(username).inbox

    assert File.read!(Path.join(inbox, "env.sh")) =~ "GITHUB_TOKEN='#{grant.placeholder}'"
    assert File.read!(Path.join(inbox, "git/github.com")) =~ "password=#{grant.placeholder}"

    refute inbox
           |> Path.join("**/*")
           |> Path.wildcard()
           |> Enum.any?(&(File.regular?(&1) and File.read!(&1) =~ "ghp_real_value"))
  end
end
