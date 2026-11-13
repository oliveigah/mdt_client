defmodule MDTClient.Sandbox.DesktopNotice do
  @moduledoc """
  The desktop notification for an approval that waits for you
  (`MDTClient.Desktop.Notifications`): what waits, who asked, and how long
  it waits. Clicking it opens the approval in MDT.

  The thread it asked from (`MDTClient.Sandbox.Approval.asked_from/2`) comes
  first, so you know which of your agents waits. What the agent wrote (its
  reason) is quoted, as on the approval's card,
  and nothing in a notification is a way to decide: the card is, with the
  facts MDT worked out beside it.
  """

  alias MDTClient.Sandbox.{Approval, Grant, HostCommand}

  @doc "The notice for `approval`, waiting in `username`'s sandbox; `grant` is its grant, if any."
  @spec notice(String.t(), Approval.t(), Grant.t() | nil, DateTime.t()) ::
          MDTClient.Desktop.Notifications.notice()
  def notice(username, %Approval{} = approval, grant, now \\ DateTime.utc_now()) do
    {summary, lines} = text(approval, grant)

    %{
      summary: summary,
      body: Enum.join(Enum.reject(lines ++ [gives_up(approval, now)], &(&1 in [nil, ""])), "\n"),
      scope: username,
      open: "/tools/sandbox/approvals?focus=" <> approval.id
    }
  end

  defp text(%Approval{kind: :activation, need: need} = approval, nil) do
    {"#{agent(approval)} asks for access you haven't set up",
     [from(approval), need, reason(approval)]}
  end

  defp text(%Approval{kind: :activation} = approval, grant) do
    minutes = if approval.minutes, do: "for #{approval.minutes} min", else: nil

    {"#{agent(approval)} asks to turn on #{name(grant)}",
     [from(approval), minutes && String.capitalize(minutes), reason(approval)]}
  end

  defp text(%Approval{kind: :request} = approval, grant),
    do: {"An agent wants to use #{name(grant)}", [approval.title]}

  defp text(%Approval{kind: :connection} = approval, grant),
    do: {"An agent wants to connect through #{name(grant)}", [approval.pattern]}

  defp text(%Approval{kind: :command, stage: :output, run: run} = approval, _grant),
    do:
      {"A command's output waits for you",
       [from(approval), HostCommand.title(approval.script), ended(run)]}

  defp text(%Approval{kind: :command} = approval, _grant) do
    {"#{agent(approval)} asks to run a command on this machine",
     [from(approval), HostCommand.title(approval.script), reason(approval)]}
  end

  defp agent(%Approval{agent: agent}) when is_binary(agent) and agent != "" do
    {first, rest} = String.split_at(String.trim(agent), 1)
    String.upcase(first) <> rest
  end

  defp agent(_approval), do: "An agent"

  # The thread it asked from, so you know which one waits before opening MDT.
  defp from(approval) do
    case Approval.asked_from(approval) do
      nil -> nil
      from -> "From " <> from
    end
  end

  defp name(%Grant{name: name}), do: name
  defp name(nil), do: "a grant"

  defp reason(%Approval{reason: reason}) when is_binary(reason) and reason != "",
    do: "Reason: “#{String.trim(reason)}”"

  defp reason(_approval), do: nil

  defp ended(%{exit: exit} = run) do
    cond do
      run[:timed_out] -> "Hit its time limit (exit #{exit})"
      run[:stopped] -> "Stopped by you (exit #{exit})"
      true -> "Exit #{exit}"
    end
  end

  defp ended(_run), do: nil

  defp gives_up(%Approval{deadline: deadline}, now) do
    seconds = max(DateTime.diff(deadline, now), 0)
    "Gives up in #{HostCommand.seconds_words(round_up(seconds))} unless you decide."
  end

  # "2 min 59 s" reads worse than "3 min" in a notification.
  defp round_up(seconds) when seconds > 90, do: div(seconds + 59, 60) * 60
  defp round_up(seconds), do: seconds
end
