defmodule MDTClient.Sandbox.ServerTest do
  use ExUnit.Case, async: true

  alias MDTClient.Sandbox
  alias MDTClient.Sandbox.Server
  alias MDTClient.Vault.Store

  setup do
    MDTClient.VaultHelpers.unlocked_identity("sandbox")
  end

  defp github(username, value \\ "ghp_real_value") do
    {:ok, grant} =
      Sandbox.create_grant(username, %{"recipe" => "github", "name" => "GitHub", "value" => value})

    {:ok, grant} = Sandbox.turn_on(username, grant.id, 60)
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

  test "grants check what each kind needs, and values never leave the server", %{
    username: username
  } do
    assert {:error, errors} = Sandbox.create_grant(username, %{"recipe" => "token", "name" => ""})
    assert Map.keys(errors) |> Enum.sort() == [:env, :hosts, :name, :value]

    assert {:error, %{destinations: _}} =
             Sandbox.create_grant(username, %{
               "recipe" => "network",
               "name" => "VPN",
               "destinations" => "10.0.0.0/99"
             })

    grant = github(username)
    assert String.starts_with?(grant.placeholder, "ghp_")
    refute inspect(Sandbox.snapshot(username)) =~ "ghp_real_value"
    assert Sandbox.snapshot(username).values[grant.id]
  end

  test "reads go through with the real value; requests without a placeholder pass untouched",
       %{username: username} do
    grant = github(username)

    assert {:forward, headers, [{"ghp_real_value", placeholder}]} =
             authorize(username, request(grant))

    assert {"authorization", "token ghp_real_value"} in headers
    assert placeholder == grant.placeholder

    plain = %{request(grant) | headers: [{"accept", "*/*"}]}
    assert {:forward, [{"accept", "*/*"}], []} = authorize(username, plain)
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
    assert %{"code" => "mdt_grant_off", "grant" => "GitHub"} = Jason.decode!(body)
  end

  test "a push waits for you; retries join it; allowing answers all of them", %{
    username: username
  } do
    grant = github(username)

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
    grant = github(username)

    push =
      request(grant, %{host: "github.com", method: "POST", path: "/o/r.git/git-receive-pack"})

    denied = authorize_async(username, push)
    :ok = Sandbox.decide(username, wait_for_approval(username).id, :deny)
    assert {:deny, 403, body} = Task.await(denied)
    assert body =~ "mdt_denied_by_user"

    similar = authorize_async(username, push)
    :ok = Sandbox.decide(username, wait_for_approval(username).id, {:allow_for, 10})
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

  test "a rule set to deny refuses without asking", %{username: username} do
    grant = github(username)
    {:ok, _} = Sandbox.set_rule(username, grant.id, "reads", :deny)

    assert {:deny, 403, body} = authorize(username, request(grant))
    assert body =~ "mdt_denied"
  end

  test "minted values come from the command, and are reused", %{username: username} do
    {:ok, grant} =
      Sandbox.create_grant(username, %{
        "recipe" => "google",
        "name" => "Google",
        "mint" => "echo ya29.minted-$((40 + 2))"
      })

    {:ok, grant} = Sandbox.turn_on(username, grant.id, 60)

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
        "recipe" => "database",
        "name" => "Tunnel",
        "destinations" => "127.0.0.1:5433\n10.20.0.0/16:5432"
      })

    {:ok, _} = Sandbox.turn_on(username, tunnel.id, 60)
    {:ok, _} = Sandbox.set_per_connection(username, tunnel.id, :allow)

    assert destination.({127, 0, 0, 1}, 5433) == :ok
    assert {:deny, _} = destination.({127, 0, 0, 1}, 4000)
    assert destination.({10, 20, 4, 12}, 5432) == :ok

    {:ok, _} = Sandbox.set_per_connection(username, tunnel.id, :ask)

    held =
      Task.async(fn ->
        Server.call(username, {:destination, {10, 20, 4, 12}, 5432}, :infinity)
      end)

    :ok = Sandbox.decide(username, wait_for_approval(username).id, :allow_once)
    assert Task.await(held) == :ok
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
