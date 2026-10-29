defmodule MDTClientWeb.GitLive.Push do
  @moduledoc false

  alias MDTClient.Git.Error

  # Use configured remotes, including ones that have no remote-tracking refs yet.
  def upstream_confirmation(tab) do
    case Enum.find(tab.snapshot.branches, & &1.current?) do
      %{upstream: nil} = branch when tab.remotes != [] ->
        %{
          title: "Set an upstream for #{branch.name}?",
          message:
            "Choose where to push this branch. Future pushes and pulls will use this upstream.",
          icon: "hero-cloud-arrow-up",
          cancel_label: "Abort push",
          choices:
            tab.remotes
            |> Enum.sort_by(&{&1.name != "origin", &1.name})
            |> Enum.map(fn remote ->
              %{
                id: "upstream-" <> Base.url_encode64(remote.name, padding: false),
                label: "Push to #{remote.name}/#{branch.name}",
                hint: "Push and set #{remote.name}/#{branch.name} as the upstream.",
                icon: "hero-cloud-arrow-up",
                action:
                  {:push,
                   [
                     remote: remote.name,
                     branch: branch.name,
                     destination: branch.name,
                     set_upstream: true
                   ]}
              }
            end)
        }

      _already_tracking_or_no_destination ->
        nil
    end
  end

  def recovery(tab, %Error{args: ["push" | _]} = error) do
    cond do
      error.message =~ "has no upstream branch" ->
        upstream_confirmation(tab)

      error.message =~ "The upstream branch of your current branch does not match" ->
        mismatch_confirmation(tab)

      true ->
        rejected_confirmation(tab, error)
    end
  end

  def recovery(_tab, _error), do: nil

  # Only Git's porcelain rejection records qualify. Server policy, hooks,
  # authentication and transport errors must never suggest overriding history.
  defp rejected_confirmation(tab, error) do
    with [url] <-
           Regex.scan(~r/^To (.+)$/m, error.output, capture: :all_but_first) |> List.flatten(),
         [remote] <- matching_remotes(tab.remotes, error.args, url),
         [[source, destination, reason]] <-
           Regex.scan(
             ~r/^!\trefs\/heads\/([^:\t]+):refs\/heads\/([^\t]+)\t\[rejected\] \((non-fast-forward|fetch first|stale info)\)$/m,
             error.output,
             capture: :all_but_first
           ) do
      tracked = Enum.find(tab.snapshot.branches, &(&1.name == "#{remote.name}/#{destination}"))
      expected = if tracked, do: tracked.target, else: ""
      opts = [remote: remote.name, branch: source, destination: destination]

      opts =
        if "--set-upstream" in error.args, do: Keyword.put(opts, :set_upstream, true), else: opts

      target = "#{remote.name}/#{destination}"

      %{
        title:
          if(reason == "stale info", do: "The remote branch changed", else: "Push was rejected"),
        message:
          "#{target} has history this push would replace. You can abort and pull or fetch to review it, " <>
            "or choose how to retry pushing #{source}.",
        icon: "hero-cloud-arrow-up",
        cancel_label: "Abort push",
        choices: [
          %{
            id: "force-with-lease",
            label: "Force push with lease",
            hint:
              "Replace remote history only if it still matches the last fetched state. " <>
                "Refuse if the remote changed or has not been fetched.",
            icon: "hero-shield-check",
            action: {:push, Keyword.put(opts, :force_with_lease, {destination, expected})}
          },
          %{
            id: "force",
            label: "Force push",
            hint: "Replace remote history even if it changed. Commits on the remote may be lost.",
            icon: "hero-exclamation-triangle",
            danger: true,
            action: {:push, Keyword.put(opts, :force, true)}
          }
        ]
      }
    else
      _not_recoverable -> nil
    end
  end

  defp matching_remotes(remotes, args, url) do
    # A selected remote remains unambiguous when several remotes share a URL.
    selected =
      case Enum.drop_while(args, &(&1 != "--")) do
        ["--", remote | _] -> remote
        _implicit -> nil
      end

    Enum.filter(remotes, &(&1.push_url == url and (is_nil(selected) or &1.name == selected)))
  end

  defp mismatch_confirmation(tab) do
    current = Enum.find(tab.snapshot.branches, & &1.current?)

    with %{upstream: upstream} when is_binary(upstream) <- current,
         remote when not is_nil(remote) <-
           tab.remotes
           |> Enum.sort_by(&(-String.length(&1.name)))
           |> Enum.find(&String.starts_with?(upstream, &1.name <> "/")) do
      destination = String.replace_prefix(upstream, remote.name <> "/", "")

      %{
        title: "Choose the remote branch",
        message:
          "#{current.name} tracks #{upstream}, whose name is different. Choose where to push.",
        icon: "hero-cloud-arrow-up",
        cancel_label: "Abort push",
        choices: [
          %{
            id: "tracked-upstream",
            label: "Push to #{upstream}",
            hint: "Keep the existing upstream.",
            icon: "hero-cloud-arrow-up",
            action: {:push, [remote: remote.name, branch: current.name, destination: destination]}
          },
          %{
            id: "same-name-upstream",
            label: "Push to #{remote.name}/#{current.name}",
            hint: "Set the branch with the same name as the new upstream.",
            icon: "hero-arrow-path",
            action:
              {:push,
               [
                 remote: remote.name,
                 branch: current.name,
                 destination: current.name,
                 set_upstream: true
               ]}
          }
        ]
      }
    else
      _no_upstream -> nil
    end
  end
end
