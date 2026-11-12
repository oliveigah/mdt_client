defmodule MDTClientWeb.SandboxLiveTest do
  use MDTClientWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias MDTClient.Sandbox
  alias MDTClient.Sandbox.Server

  setup %{conn: conn} do
    sign_in(conn)
  end

  defp github(username, on? \\ true) do
    {:ok, grant} =
      Sandbox.create_grant(username, %{
        "recipe" => "github",
        "name" => "GitHub",
        "value" => "ghp_real"
      })

    if on?, do: {:ok, _} = Sandbox.turn_on(username, grant.id, 60)
    grant
  end

  # A git push held for approval, as the proxy would hold it.
  defp hold_push(username, grant) do
    request = %{
      host: "github.com",
      method: "POST",
      path: "/oliveigah/klife.git/git-receive-pack",
      headers: [{"authorization", "token #{grant.placeholder}"}],
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
          {~p"/tools/sandbox/settings", "#settings-image"}
        ] do
      {:ok, view, _html} = live(conn, path)
      assert has_element?(view, selector)
      assert has_element?(view, "#sandbox-nav")
      assert has_element?(view, "#sandbox-health")
      assert has_element?(view, "#tool-switch-sandbox[aria-current=page]")
    end
  end

  test "a new sandbox points at building the image first", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox")
    assert has_element?(view, "#vm-build[href='/tools/sandbox/settings']")
    assert has_element?(view, "#vm-first-run")
    refute has_element?(view, "#vm-start")
  end

  test "the overview spells out how to open this VM in Zed", %{conn: conn, username: username} do
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox")
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

    view |> element("#allow-once-#{approval.id}") |> render_click()
    assert {:forward, _headers, _scrub} = Task.await(task)
    refute has_element?(view, "#approval-#{approval.id}")
    assert has_element?(view, "#decided-#{approval.id}")
    refute has_element?(notes, "#sandbox-waiting")
  end

  test "adding a grant takes its value and lands on its page", %{conn: conn, username: username} do
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/grants")

    view |> element("#add-grant") |> render_click()
    view |> element("#recipe-token") |> render_click()
    assert has_element?(view, "#recipe-guide")

    view |> form("#add-grant-form", grant: %{name: "Stripe"}) |> render_submit()
    assert has_element?(view, "#grant-error-value")

    view
    |> form("#add-grant-form",
      grant: %{name: "Stripe", env: "STRIPE_API_KEY", hosts: "api.stripe.com", value: "sk_test_1"}
    )
    |> render_submit()

    assert_patch(view, ~p"/tools/sandbox/grants/stripe")
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

  test "rules change from the grant page", %{conn: conn, username: username} do
    grant = github(username)
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/grants/#{grant.id}")

    view |> element("#rule-action-#{grant.id}-push-allow") |> render_click()
    assert has_element?(view, "#rule-action-#{grant.id}-push-allow[aria-checked=true]")
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
  end

  test "settings refuse unsafe folders and Containerfiles without a FROM", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/settings")

    view |> form("#share-form", share: %{path: "~", mode: "rw"}) |> render_submit()
    assert has_element?(view, "#share-error", "Your home folder holds your credentials")

    view |> form("#containerfile-form", image: %{containerfile: "RUN true"}) |> render_submit()
    assert has_element?(view, "#containerfile-error")

    view
    |> form("#containerfile-form", image: %{containerfile: "FROM debian:bookworm-slim\n"})
    |> render_submit()

    assert has_element?(view, "#notices", "Containerfile saved")

    view |> form("#vm-form", vm: %{cpus: "0"}) |> render_submit()
    assert render(view) =~ "Enter a whole number from 1 to 64."
  end

  test "settings show the image's name, its builds, what the VM keeps and its memory", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/settings")

    assert has_element?(view, "#image-name[value='mdt_agent_sdb_image']")
    assert has_element?(view, "#builds-empty")
    assert has_element?(view, "#settings-folders", "/root")
    assert has_element?(view, "#settings-folders", "/cache")
    assert has_element?(view, "#snapshots-empty")
    assert has_element?(view, "#settings-vm-memory")
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

    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/settings")

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

  test "the VM's memories open for review", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/settings")

    if has_element?(view, "#vm-memory-review") do
      view |> element("#vm-memory-review") |> render_click()
      assert has_element?(view, "#memory-review-empty")
      view |> element("#memory-close") |> render_click()
      refute has_element?(view, "#memory-review")
    end
  end
end
