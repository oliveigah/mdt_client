defmodule MDTClientWeb.SandboxLiveTest do
  use MDTClientWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias MDTClient.Sandbox
  alias MDTClient.Sandbox.{Event, Server}

  setup %{conn: conn} do
    sign_in(conn)
  end

  defp github(username, on? \\ true) do
    {:ok, grant} =
      Sandbox.create_grant(username, %{
        "kind" => "token",
        "preset" => "github",
        "name" => "GitHub",
        "purpose" => "Push to oliveigah/klife",
        "hosts" => "api.github.com, github.com",
        "env" => "GH_TOKEN",
        "git" => "true",
        "prefix" => "ghp_",
        "value" => "ghp_real"
      })

    if on?, do: {:ok, _} = Sandbox.turn_on(username, grant.id, 60)
    grant
  end

  defp wait_for(username, kind) do
    Enum.find_value(1..100, fn _ ->
      case Enum.find(Sandbox.snapshot(username).waiting, &(&1.kind == kind)) do
        nil -> Process.sleep(10) && nil
        approval -> approval
      end
    end)
  end

  # A git push held for approval, as the proxy would hold it.
  defp hold_push(username, grant) do
    request = %{
      host: "github.com",
      method: "POST",
      path: "/oliveigah/klife.git/git-receive-pack",
      headers: [
        {"host", "github.com"},
        {"authorization", "token #{grant.placeholder}"},
        {"content-type", "application/x-git-receive-pack-request"}
      ],
      body: ""
    }

    task = Task.async(fn -> Server.call(username, {:authorize, request}, :infinity) end)

    approval =
      Enum.find_value(1..100, fn _ ->
        case Sandbox.snapshot(username).waiting do
          [approval | _] -> approval
          [] -> Process.sleep(10) && nil
        end
      end)

    {task, approval}
  end

  test "every page renders behind the sidebar", %{conn: conn} do
    for {path, selector} <- [
          {~p"/tools/sandbox", "#vm-card"},
          {~p"/tools/sandbox/approvals", "#no-waiting-approvals"},
          {~p"/tools/sandbox/grants", "#grants-on"},
          {~p"/tools/sandbox/activity", "#activity-log"},
          {~p"/tools/sandbox/settings", "#settings-shares"},
          {~p"/tools/sandbox/setup", "#setup-steps"}
        ] do
      {:ok, view, _html} = live(conn, path)
      assert has_element?(view, selector)
      assert has_element?(view, "#sandbox-nav")
      assert has_element?(view, "#sandbox-health")
      assert has_element?(view, "#tool-switch-sandbox[aria-current=page]")
    end
  end

  test "a new sandbox points at setup, which starts with building the image", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox")
    assert has_element?(view, "#vm-build[href='/tools/sandbox/setup']")
    assert has_element?(view, "#vm-first-run")
    assert has_element?(view, "#sandbox-nav-setup-todo")
    refute has_element?(view, "#vm-start")

    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/setup")
    assert has_element?(view, "#setup-build")
    refute has_element?(view, "#setup-step-image[data-done]")
    refute has_element?(view, "#setup-step-folders[data-done]")
    assert has_element?(view, "#setup-start[disabled]")
  end

  test "setup spells out how to open this VM in Zed", %{conn: conn, username: username} do
    {:ok, overview, _html} = live(conn, ~p"/tools/sandbox")
    refute has_element?(overview, "#connect-zed")

    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/setup")
    name = Server.vm_name(username)

    assert has_element?(view, "#connect-ssh-config", "ssh serve #{name} --stdio")
    assert has_element?(view, "#connect-ssh-config", "ForwardAgent no")
    assert has_element?(view, "#connect-profile", "context_servers")
    assert has_element?(view, "#connect-profile", "/bin/bash")
    refute has_element?(view, "#connect-profile", "agent_servers")
    assert has_element?(view, "#connect-open", "zed ssh://mdt-sandbox")
  end

  test "the title bar of every tool shows held requests, and follows decisions", %{
    conn: conn,
    username: username
  } do
    grant = github(username)
    {:ok, notes, _html} = live(conn, ~p"/tools/notes")
    refute has_element?(notes, "#sandbox-waiting")

    {task, approval} = hold_push(username, grant)
    assert has_element?(notes, "#sandbox-waiting-count", "1")

    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/approvals")
    assert has_element?(view, "#approval-#{approval.id}", "Push to oliveigah/klife")

    assert has_element?(view, "#approval-request-#{approval.id}")
    assert has_element?(view, "#copy-curl-#{approval.id}[phx-hook=CopyText]")
    assert has_element?(view, "#copy-curl-text-#{approval.id}", "$GH_TOKEN")
    refute has_element?(view, "#copy-curl-text-#{approval.id}", grant.placeholder)
    assert has_element?(view, "#approval-headers-#{approval.id}", "GitHub")

    view |> element("#allow-once-#{approval.id}") |> render_click()
    assert {:forward, _headers, _scrub} = Task.await(task)
    refute has_element?(view, "#approval-#{approval.id}")
    assert has_element?(view, "#decided-#{approval.id}")
    refute has_element?(notes, "#sandbox-waiting")
  end

  test "adding a grant takes its value and lands on its page", %{conn: conn, username: username} do
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/grants")

    view |> element("#add-grant") |> render_click()
    assert has_element?(view, "#type-network")
    assert has_element?(view, "#preset-github")
    view |> element("#type-token") |> render_click()
    assert has_element?(view, "#preset-guide")

    view |> form("#add-grant-form", grant: %{name: "Stripe"}) |> render_submit()
    assert has_element?(view, "#grant-error-value")
    assert has_element?(view, "#grant-error-purpose")

    view
    |> form("#add-grant-form",
      grant: %{
        name: "Stripe",
        purpose: "Test-mode charges for the checkout work",
        env: "STRIPE_API_KEY",
        hosts: "api.stripe.com",
        prefix: "sk_test_",
        value: "sk_test_1"
      }
    )
    |> render_submit()

    assert_patch(view, ~p"/tools/sandbox/grants/stripe")
    assert has_element?(view, "#grant-detail-stripe", "Test-mode charges")
    assert has_element?(view, "#grant-uses")
    assert [%{placeholder: "sk_test_" <> _}] = Sandbox.snapshot(username).grants
    assert has_element?(view, "#grant-value-card")
    refute has_element?(view, "#grant-no-value")
    refute render(view) =~ "sk_test_1"

    view |> form("#grant-value-form", value: %{value: "sk_test_2"}) |> render_submit()
    assert has_element?(view, "#notices", "Value replaced")
    assert Sandbox.snapshot(username).values["stripe"]
  end

  test "a grant is switched on for the duration picked, and off again", %{
    conn: conn,
    username: username
  } do
    grant = github(username, false)
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/grants")

    view |> element("#grant-duration-#{grant.id}-15") |> render_click()
    before_switch = DateTime.utc_now() |> DateTime.truncate(:second)
    view |> element("#grant-switch-#{grant.id}") |> render_click()
    after_switch = DateTime.utc_now() |> DateTime.truncate(:second)
    assert has_element?(view, "#grants-on #grant-row-#{grant.id}")
    active = Enum.find(Sandbox.snapshot(username).grants, &(&1.id == grant.id))

    assert has_element?(
             view,
             "#grant-left-#{grant.id} #grant-clock-#{grant.id}-#{DateTime.to_unix(active.expires_at)}"
           )

    assert DateTime.compare(active.expires_at, DateTime.add(before_switch, 15 * 60)) != :lt
    assert DateTime.compare(active.expires_at, DateTime.add(after_switch, 15 * 60)) != :gt

    view |> element("#grant-switch-#{grant.id}") |> render_click()
    assert has_element?(view, "#grants-off #grant-row-#{grant.id}")
  end

  test "a preset fills the form; minted tokens need no value", %{conn: conn, username: username} do
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/grants")

    view |> element("#add-grant") |> render_click()
    view |> element("#preset-google") |> render_click()
    assert has_element?(view, "#grant-source-minted[checked]")

    view
    |> form("#add-grant-form", grant: %{name: "GCP", source: "minted"})
    |> render_submit()

    assert_patch(view, ~p"/tools/sandbox/grants/gcp")

    assert [
             %{
               preset: :google,
               file_env: ["CLOUDSDK_AUTH_ACCESS_TOKEN_FILE"],
               source: {:minted, _}
             }
           ] =
             Sandbox.snapshot(username).grants
  end

  test "every use of a grant can be let through for a while, from its page", %{
    conn: conn,
    username: username
  } do
    grant = github(username)
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/grants/#{grant.id}")

    view |> element("#allow-all-#{grant.id}-60") |> render_click()
    assert has_element?(view, "#grant-allowances", "Every use")

    [%{allowances: [allowance]}] = Sandbox.snapshot(username).grants
    view |> element("#revoke-allowance-#{allowance.id}") |> render_click()
    refute has_element?(view, "#grant-allowances", "Every use")
  end

  test "an agent's ask shows its reason, and is answered from its card", %{
    conn: conn,
    username: username
  } do
    grant = github(username, false)

    asking =
      Task.async(fn ->
        {:ok, ask} =
          Server.call(
            username,
            {:request_access,
             %{
               grant: grant.id,
               reason: "push the fix",
               agent: "codex",
               minutes: 30,
               thread: "Fix the push flow",
               folder: "/work/klife"
             }}
          )

        Server.call(username, {:await, ask.id, 5_000}, 6_000)
      end)

    ask = wait_for(username, :activation)
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/approvals")

    assert has_element?(view, "#approval-#{ask.id}", "Turn on GitHub for 30 min")
    assert has_element?(view, "#approval-claims-#{ask.id}", "push the fix")
    assert has_element?(view, "#approval-thread-#{ask.id}-title", "Fix the push flow")
    assert has_element?(view, "#approval-thread-#{ask.id}-folder", "/work/klife")
    assert has_element?(view, "#activation-minutes-#{ask.id}-30[checked]")

    view
    |> form("#activation-form-#{ask.id}", ask: %{minutes: "60", uses: "all"})
    |> render_submit()

    assert {:ok, %{status: :allowed}, %{state: :on, allowances: [%{pattern: :all}]}} =
             Task.await(asking)

    assert has_element?(view, "#decided-#{ask.id}", "codex asked for GitHub")
    assert has_element?(view, "#decided-#{ask.id}", "every use allowed")
  end

  test "an ask for something new is set up from its card", %{conn: conn, username: username} do
    {:ok, ask} =
      Server.call(
        username,
        {:request_access, %{need: "Grafana at 10.9.0.4:3000", reason: "read the dashboards"}}
      )

    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/approvals")
    view |> element("#setup-ask-#{ask.id}") |> render_click()
    assert has_element?(view, "#add-grant-dialog", "Grafana at 10.9.0.4:3000")
    view |> element("#type-network") |> render_click()

    view
    |> form("#add-grant-form", grant: %{name: "Grafana", destinations: "10.9.0.4:3000"})
    |> render_submit()

    assert_patch(view, ~p"/tools/sandbox/grants/grafana")

    assert [%{state: :on, purpose: "Grafana at 10.9.0.4:3000"}] =
             Sandbox.snapshot(username).grants

    assert [%{status: :allowed, decision: {:set_up, "grafana"}}] =
             Sandbox.snapshot(username).history
  end

  test "removing a grant asks first", %{conn: conn, username: username} do
    grant = github(username)
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/grants/#{grant.id}")

    view |> element("#delete-grant") |> render_click()
    view |> element("#sandbox-confirm-accept") |> render_click()

    assert_patch(view, ~p"/tools/sandbox/grants")
    refute has_element?(view, "#grant-row-#{grant.id}")
  end

  test "activity filters by outcome and words", %{conn: conn, username: username} do
    grant = github(username)

    Server.call(
      username,
      {:authorize,
       %{
         host: "paste.example.net",
         method: "POST",
         path: "/new",
         headers: [{"authorization", "token #{grant.placeholder}"}],
         body: ""
       }}
    )

    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/activity")
    view |> form("#activity-filters", %{group: "blocked", q: "", grant: ""}) |> render_change()
    assert has_element?(view, "#activity-log li[id^=event-]", "paste.example.net")
    refute has_element?(view, "#activity-log li[id^=event-]", "added")

    view
    |> form("#activity-filters", %{group: "all", q: "no such host", grant: ""})
    |> render_change()

    refute has_element?(view, "#activity-log li[id^=event-]")
    assert has_element?(view, "#activity-empty", "Nothing matches")
  end

  test "settings refuse unsafe folders and Containerfiles without a FROM", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/settings")

    view |> form("#share-form", share: %{path: "~", mode: "rw"}) |> render_submit()
    assert has_element?(view, "#share-error", "Your home folder holds your credentials")

    view |> form("#vm-form", vm: %{cpus: "0"}) |> render_submit()
    assert render(view) =~ "Enter a whole number from 1 to 64."

    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/settings?tab=image")

    view |> form("#containerfile-form", image: %{containerfile: "RUN true"}) |> render_submit()
    assert has_element?(view, "#containerfile-error")

    view
    |> form("#containerfile-form", image: %{containerfile: "FROM debian:bookworm-slim\n"})
    |> render_submit()

    assert has_element?(view, "#notices", "Containerfile saved")
  end

  test "folders picked in the folder dialog are shared together", %{
    conn: conn,
    username: username
  } do
    base = Path.join(System.tmp_dir!(), "share-pick-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(base) end)
    [one, two] = for name <- ~w(one two), do: Path.join(base, name)
    Enum.each([one, two], &File.mkdir_p!/1)

    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/settings")
    assert has_element?(view, "#share-pick[phx-hook]")

    render_hook(view, "add_shares", %{
      "paths" => [one, two, Path.join(base, "gone")],
      "mode" => "ro"
    })

    assert [%{path: ^one, mode: :ro}, %{path: ^two, mode: :ro}] =
             Sandbox.snapshot(username).settings.shares

    assert has_element?(view, "#share-0", "one")
    assert has_element?(view, "#share-1", "two")
    assert has_element?(view, "#notices", "2 folders shared")
    assert has_element?(view, "#share-error", "gone: That folder does not exist.")

    render_hook(view, "folder_picker_unavailable", %{"reason" => "Only in the desktop app."})
    assert has_element?(view, "#share-error", "Type the folder's path instead.")
  end

  test "settings sit in tabs, and each tab shows its own panels", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/settings")
    assert has_element?(view, "#settings-tab-general[aria-current=page]")
    assert has_element?(view, "#settings-vm")
    refute has_element?(view, "#settings-image")

    view |> element("#settings-tab-host") |> render_click()
    assert_patch(view, ~p"/tools/sandbox/settings?tab=host")
    assert has_element?(view, "#settings-host")
    assert has_element?(view, "#settings-network")
    refute has_element?(view, "#settings-shares")

    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/settings?tab=nonsense")
    assert has_element?(view, "#settings-tab-general[aria-current=page]")
  end

  test "settings show the image's name, its builds, what the VM keeps and its memory", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/settings?tab=storage")

    assert has_element?(view, "#settings-folders", "/root")
    assert has_element?(view, "#settings-folders", "/cache")
    assert has_element?(view, "#snapshots-empty")
    assert has_element?(view, "#settings-vm-memory")

    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/settings?tab=image")

    assert has_element?(view, "#image-name[value='mdt_agent_sdb_image']")
    assert has_element?(view, "#builds-empty")
    assert has_element?(view, "#image-setup-guide")
    refute has_element?(view, "#containerfile-default-differs")

    view |> form("#image-name-form", image_name: %{name: "Not Valid"}) |> render_submit()
    assert has_element?(view, "#image-name-error")

    view |> form("#image-name-form", image_name: %{name: "agentbox"}) |> render_submit()
    refute has_element?(view, "#image-name-error")
    assert has_element?(view, "#image-name[value='agentbox']")
  end

  test "an older recipe can adopt the current default explicitly", %{
    conn: conn,
    username: username
  } do
    {:ok, _} =
      Sandbox.update_settings(username, %{"containerfile" => "FROM debian:bookworm-slim\n"})

    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/settings?tab=image")

    assert has_element?(view, "#containerfile-default-differs")
    view |> element("#containerfile-reset") |> render_click()
    view |> form("#containerfile-form") |> render_submit()
    refute has_element?(view, "#containerfile-default-differs")

    assert Sandbox.snapshot(username).settings.containerfile ==
             MDTClient.Sandbox.Image.default_containerfile()
  end

  test "creating the VM first asks about Home, Cache and memory", %{
    conn: conn,
    username: username
  } do
    pid = GenServer.whereis(MDTClient.Vault.Store.via(Server, username))

    :sys.replace_state(pid, fn state ->
      %{state | image: %{state.image | loaded?: true, tag: "box:2026-11-12.1"}}
    end)

    {:ok, view, _html} = live(conn, ~p"/tools/sandbox")
    view |> element("#vm-start") |> render_click()

    assert has_element?(view, "#create-dialog")
    assert has_element?(view, "#create-home-keep[checked]")
    assert has_element?(view, "#create-home-empty")
    assert has_element?(view, "#create-cache-clear")

    view |> element("#create-cancel") |> render_click()
    refute has_element?(view, "#create-dialog")
  end

  test "an existing VM can be recreated on demand, from an older tag", %{
    conn: conn,
    username: username
  } do
    pid = GenServer.whereis(MDTClient.Vault.Store.via(Server, username))

    :sys.replace_state(pid, fn state ->
      %{
        state
        | image: %{state.image | loaded?: true, tag: "box:2026-11-12.2"},
          vm: %{state.vm | exists?: true},
          created_ref: "box:2026-11-12.1"
      }
    end)

    {:ok, view, _html} = live(conn, ~p"/tools/sandbox")
    assert has_element?(view, "#vm-image", "box:2026-11-12.1")
    refute has_element?(view, "#vm-image", "box:2026-11-12.2")
    assert has_element?(view, "#vm-next-image", "box:2026-11-12.2")
    view |> element("#vm-recreate-any") |> render_click()

    assert has_element?(view, "#create-dialog", "it runs 2026-11-12.1 now")
    assert has_element?(view, "#create-confirm", "Recreate")
  end

  test "the VM's memories open for review, from settings and the overview", %{conn: conn} do
    for {path, button} <- [
          {~p"/tools/sandbox/settings?tab=storage", "#vm-memory-review"},
          {~p"/tools/sandbox", "#overview-memory-review"}
        ] do
      {:ok, view, _html} = live(conn, path)
      assert has_element?(view, "#overview-memory, #settings-vm-memory")

      if has_element?(view, button) do
        view |> element(button) |> render_click()
        assert has_element?(view, "#memory-review-empty")
        view |> element("#memory-close") |> render_click()
        refute has_element?(view, "#memory-review")
      end
    end
  end

  # Events as the server logs them, newest first: `conn 120` down to `conn 1`.
  defp put_events(username, count) do
    pid = GenServer.whereis(MDTClient.Vault.Store.via(Server, username))
    now = DateTime.utc_now()

    events =
      for n <- count..1//-1 do
        %Event{
          id: "event-t#{n}",
          at: DateTime.add(now, n - count, :second),
          outcome: :tunnel,
          summary: "conn #{n}",
          host: "h#{n}.example"
        }
      end

    :sys.replace_state(pid, &%{&1 | events: events ++ &1.events})
  end

  defp row(n), do: "#activity-log #event-event-t#{n}"

  test "the server pages activity from a cursor", %{username: username} do
    put_events(username, 120)

    assert ~w(event-t99 event-t98 event-t97) ==
             username |> Sandbox.events(%{before: "event-t100", limit: 3}) |> Enum.map(& &1.id)

    assert [%{id: "event-t2"}] = Sandbox.events(username, %{before: "event-t3", q: "conn 2"})
    assert [] == Sandbox.events(username, %{before: "event-gone"})
  end

  test "activity shows 50 events a page and pages back and forth", %{
    conn: conn,
    username: username
  } do
    put_events(username, 120)
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/activity")

    assert has_element?(view, row(120))
    assert has_element?(view, row(71))
    refute has_element?(view, row(70))
    assert has_element?(view, "#activity-range", "Newest 50")
    assert has_element?(view, "#activity-newer[disabled]")

    view |> element("#activity-older") |> render_click()
    assert has_element?(view, row(70))
    assert has_element?(view, row(21))
    refute has_element?(view, row(71))
    refute has_element?(view, row(20))
    assert has_element?(view, "#activity-range", "Page 2 · 51–100")

    # An older page stays put while activity comes in, and says so.
    send(
      view.pid,
      {:sandbox_event,
       %Event{id: "event-t121", at: DateTime.utc_now(), outcome: :tunnel, summary: "conn 121"}}
    )

    refute has_element?(view, row(121))
    assert has_element?(view, "#activity-fresh", "1 newer event")

    view |> element("#activity-newer") |> render_click()
    assert has_element?(view, row(120))
    refute has_element?(view, "#activity-fresh")

    # The newest page takes it in at the top, and keeps 50.
    send(
      view.pid,
      {:sandbox_event,
       %Event{id: "event-t122", at: DateTime.utc_now(), outcome: :tunnel, summary: "conn 122"}}
    )

    assert has_element?(view, row(122))
    assert has_element?(view, row(72))
    refute has_element?(view, row(71))
  end
end
