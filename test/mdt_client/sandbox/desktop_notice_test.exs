defmodule MDTClient.Sandbox.DesktopNoticeTest do
  use ExUnit.Case, async: true

  alias MDTClient.Sandbox.{Approval, DesktopNotice, Grant}

  @now ~U[2026-11-13 12:00:00Z]
  @grant %Grant{id: "github", name: "GitHub", kind: :token}

  defp approval(attrs) do
    struct!(
      Approval,
      Map.merge(
        %{
          id: "ask-1",
          title: "Turn on GitHub",
          requested_at: @now,
          deadline: DateTime.add(@now, 30 * 60)
        },
        attrs
      )
    )
  end

  test "an ask for a grant names the agent and the grant, and quotes its reason" do
    ask = approval(%{kind: :activation, agent: "claude", minutes: 30, reason: "push the fix"})

    assert DesktopNotice.notice("ana", ask, @grant, @now) == %{
             summary: "Claude asks to turn on GitHub",
             body: "For 30 min\nReason: “push the fix”\nGives up in 30 min unless you decide.",
             scope: "ana",
             open: "/tools/sandbox/approvals?focus=ask-1"
           }
  end

  test "an ask from a thread says which, with your home folder as ~" do
    home = System.user_home!()

    ask =
      approval(%{
        kind: :activation,
        agent: "claude",
        minutes: 30,
        reason: "push the fix",
        thread: %{title: "Fix the push flow", id: "f4cb1da2-43", folder: home <> "/projects/mdt"}
      })

    assert DesktopNotice.notice("ana", ask, @grant, @now).body ==
             "From “Fix the push flow” in ~/projects/mdt\nFor 30 min\nReason: “push the fix”\nGives up in 30 min unless you decide."

    untitled = %{ask | thread: %{title: nil, id: "f4cb1da2-43", folder: nil}}
    assert DesktopNotice.notice("ana", untitled, @grant, @now).body =~ ~r/^From thread f4cb1da2\n/
  end

  test "an ask no grant meets says what it needs" do
    ask =
      approval(%{
        kind: :activation,
        agent: "An agent",
        need: "Postgres on 10.0.0.5",
        reason: "migrate"
      })

    notice = DesktopNotice.notice("ana", ask, nil, @now)
    assert notice.summary == "An agent asks for access you haven't set up"
    assert notice.body =~ "Postgres on 10.0.0.5\nReason: “migrate”"
  end

  test "a held request and a connection say which grant, and what" do
    request =
      approval(%{
        id: "approval-9",
        kind: :request,
        title: "Push to oliveigah/klife",
        deadline: DateTime.add(@now, 179)
      })

    assert %{summary: "An agent wants to use GitHub", body: body, open: open} =
             DesktopNotice.notice("ana", request, @grant, @now)

    assert body == "Push to oliveigah/klife\nGives up in 3 min unless you decide."
    assert open == "/tools/sandbox/approvals?focus=approval-9"

    connection =
      approval(%{kind: :connection, pattern: "10.0.0.5:5432", deadline: DateTime.add(@now, 45)})

    vpn = %Grant{id: "vpn", name: "Office VPN", kind: :network}

    assert %{summary: "An agent wants to connect through Office VPN", body: body} =
             DesktopNotice.notice("ana", connection, vpn, @now)

    assert body == "10.0.0.5:5432\nGives up in 45 s unless you decide."
  end

  test "a command shows its first line; its output, how it ended" do
    run =
      approval(%{
        id: "run-1",
        kind: :command,
        agent: "codex",
        script: "mix test\nmix format",
        reason: "check it on the host"
      })

    assert %{summary: "Codex asks to run a command on this machine", body: body} =
             DesktopNotice.notice("ana", run, nil, @now)

    assert body =~ "mix test (+1 lines)\nReason: “check it on the host”"

    output = %{run | stage: :output, run: %{exit: 1, timed_out: false, stopped: false}}

    assert %{summary: "A command's output waits for you", body: body} =
             DesktopNotice.notice("ana", output, nil, @now)

    assert body =~ "mix test (+1 lines)\nExit 1"
  end
end
