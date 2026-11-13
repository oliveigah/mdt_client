defmodule MDTClientWeb.SandboxLiveCommandsTest do
  @moduledoc "Host commands on the sandbox's pages: their cards, running, output, settings."
  use MDTClientWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias MDTClient.Sandbox
  alias MDTClient.Sandbox.Server

  setup %{conn: conn} do
    sign_in(conn)
  end

  # An agent asking to run `script`, and waiting up to 10 s for the answer.
  defp ask(username, script, attrs \\ %{}) do
    ask =
      Map.merge(
        %{script: script, reason: "check the cluster", agent: "claude", dir: "/root"},
        attrs
      )

    {:ok, approval} = Server.call(username, {:request_command, ask})
    task = Task.async(fn -> Server.call(username, {:await, approval.id, 10_000}, 11_000) end)
    {approval, task}
  end

  defp until(fun) do
    Enum.find_value(1..300, fn _ -> fun.() || (Process.sleep(10) && nil) end) ||
      flunk("it never happened")
  end

  test "a command's card shows the script in full, the facts, hints and the reason; it runs from there",
       %{conn: conn, username: username} do
    {approval, task} = ask(username, "sudo kubectl get pods\necho done")
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/approvals")

    assert has_element?(view, "#approval-#{approval.id}", "Asks to run a command on this machine")
    assert has_element?(view, "#command-script-text-#{approval.id}", "sudo kubectl get pods")
    assert has_element?(view, "#command-script-text-#{approval.id}", "echo done")
    assert has_element?(view, "#copy-script-#{approval.id}")
    assert has_element?(view, "#approval-facts-#{approval.id}", "Your home folder")
    assert has_element?(view, "#approval-hints-#{approval.id}", "Asks for root with sudo")
    assert has_element?(view, "#approval-claims-#{approval.id}", "check the cluster")
    # No allowance is offered for a command.
    refute has_element?(view, "#allow-similar-#{approval.id}")
    refute has_element?(view, "#allow-all-#{approval.id}")
    assert has_element?(view, "#command-output-#{approval.id}-send[checked]")

    view
    |> form("#command-form-#{approval.id}", run: %{output: "send"})
    |> render_submit()

    # sudo fails without a terminal; what matters is that it ran and answered.
    assert {:ok, %{status: :allowed, run: %{state: :done, exit: exit}}, nil} =
             Task.await(task, 11_000)

    assert is_integer(exit)

    # The page catches up on its own once the run ends.
    until(fn -> has_element?(view, "#decided-#{approval.id}") end)
    assert has_element?(view, "#decided-#{approval.id}", "Ran")
    assert has_element?(view, "#command-output-decided-#{approval.id}")
  end

  test "on the overview a command can be declined, but only read in full to run", %{
    conn: conn,
    username: username
  } do
    {approval, task} = ask(username, "uname -a")
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox")

    assert has_element?(view, "#approval-#{approval.id}")
    assert has_element?(view, "#review-command-#{approval.id}")
    refute has_element?(view, "#run-command-#{approval.id}")
    refute has_element?(view, "#command-script-text-#{approval.id}")

    view |> element("#decline-ask-#{approval.id}") |> render_click()
    assert {:ok, %{status: :denied, decision: :decline, run: nil}, nil} = Task.await(task)
  end

  test "output shown first waits on its own card, to send or keep", %{
    conn: conn,
    username: username
  } do
    {approval, task} = ask(username, "echo the-output; exit 2")
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/approvals")

    view
    |> form("#command-form-#{approval.id}", run: %{output: "review"})
    |> render_submit()

    until(fn ->
      Enum.find(Sandbox.snapshot(username).waiting, &(&1.stage == :output))
    end)

    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/approvals")
    assert has_element?(view, "#approval-#{approval.id}", "its output waits for you")
    assert has_element?(view, "#command-output-text-#{approval.id}", "the-output")
    assert has_element?(view, "#output-exit-#{approval.id}", "exit 2")

    view |> element("#send-output-#{approval.id}") |> render_click()

    assert {:ok, %{status: :allowed, decision: :send_output, run: %{output: "the-output\n"}}, nil} =
             Task.await(task, 11_000)

    assert has_element?(view, "#decided-#{approval.id}", "you sent the output")
  end

  test "a running command shows above the queue and can be stopped", %{
    conn: conn,
    username: username
  } do
    {approval, task} = ask(username, "sleep 30")
    :ok = Sandbox.decide(username, approval.id, {:run, :send})
    until(fn -> Sandbox.snapshot(username).running != [] end)

    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/approvals")
    assert has_element?(view, "#running-#{approval.id}", "sleep 30")
    view |> element("#stop-command-#{approval.id}") |> render_click()

    assert {:ok, %{run: %{state: :done, stopped: true}}, nil} = Task.await(task, 11_000)

    {:ok, view, _html} = live(conn, ~p"/tools/sandbox")
    refute has_element?(view, "#running-commands")
  end

  test "settings show this machine as agents see it, with your notes", %{
    conn: conn,
    username: username
  } do
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/settings?tab=host")
    assert has_element?(view, "#settings-host")
    assert has_element?(view, "#host-os")
    assert has_element?(view, "#host-tools", "Not checked yet")
    assert has_element?(view, "#host-text", "# The user's machine")

    view
    |> form("#host-notes-form", host: %{notes: "Kubernetes contexts: staging, prod"})
    |> render_submit()

    assert has_element?(view, "#host-text", "Kubernetes contexts: staging, prod")
    assert Sandbox.snapshot(username).settings.host_notes == "Kubernetes contexts: staging, prod"

    view
    |> form("#host-notes-form", host: %{notes: String.duplicate("x", 4_001)})
    |> render_submit()

    assert has_element?(view, "#host-notes-error", "4,000")
  end
end
