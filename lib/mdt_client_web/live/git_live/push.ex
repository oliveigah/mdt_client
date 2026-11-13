defmodule MDTClientWeb.GitLive.Push do
  @moduledoc false

  alias MDTClient.Git.Error

  @doc """
  What to ask before a push the user asked for, if anything: where to push a
  branch that has no upstream yet, or whether to really overwrite remote
  history with a plain force push.
  """
  def confirmation(tab, opts) do
    cond do
      opts[:force] == true -> force_confirmation(opts)
      Keyword.has_key?(opts, :remote) -> nil
      true -> upstream_confirmation(tab, opts)
    end
  end

  @doc """
  The remotes the current branch can be pushed to with a new upstream, asked
  even when it already tracks one. `opts` ride along on every choice.
  """
  def upstream_choice(tab, opts \\ []) do
    case current_branch(tab) do
      %{upstream: upstream} = branch when tab.remotes != [] ->
        %{
          title:
            if(upstream,
              do: "Change the upstream of #{branch.name}?",
              else: "Set an upstream for #{branch.name}?"
            ),
          message:
            if(upstream,
              do:
                "#{branch.name} tracks #{upstream}. Choose where to push it; " <>
                  "future pushes and pulls will use that upstream.",
              else:
                "Choose where to push this branch. Future pushes and pulls will use this upstream."
            ),
          icon: "hero-cloud-arrow-up",
          cancel_label: "Abort push",
          choices: upstream_choices(tab, branch, opts)
        }

      _no_branch_or_remote ->
        nil
    end
  end

  @doc """
  The current branch's upstream, split into the remote and branch to push to,
  with the remote commit last fetched from there (empty when none was).
  """
  def upstream_target(tab) do
    with %{upstream: upstream} = branch when is_binary(upstream) <- current_branch(tab),
         %{} = remote <- upstream_remote(tab.remotes, upstream) do
      tracked = Enum.find(tab.snapshot.branches, &(&1.kind == :remote and &1.name == upstream))

      %{
        branch: branch.name,
        remote: remote.name,
        destination: String.replace_prefix(upstream, remote.name <> "/", ""),
        expected: if(tracked, do: tracked.target, else: "")
      }
    else
      _no_upstream_on_a_remote -> nil
    end
  end

  @doc """
  A force push of the current branch to its upstream. A lease pins the remote
  commit last fetched, so remote work nobody here has seen is never replaced.
  """
  def force(tab, mode, opts \\ []) when mode in [:lease, :force] do
    case upstream_target(tab) do
      nil ->
        nil

      target ->
        override =
          case mode do
            :lease -> [force_with_lease: {target.destination, target.expected}]
            :force -> [force: true]
          end

        {:push,
         [remote: target.remote, branch: target.branch, destination: target.destination] ++
           override ++ opts}
    end
  end

  # Use configured remotes, including ones that have no remote-tracking refs yet.
  defp upstream_confirmation(tab, opts) do
    case current_branch(tab) do
      %{upstream: nil} -> upstream_choice(tab, opts)
      _already_tracking_or_no_branch -> nil
    end
  end

  defp upstream_choices(tab, branch, opts) do
    tab.remotes
    |> Enum.sort_by(&{&1.name != "origin", &1.name})
    |> Enum.map(fn remote ->
      target = "#{remote.name}/#{branch.name}"

      %{
        id: "upstream-" <> Base.url_encode64(remote.name, padding: false),
        label: "Push to #{target}",
        hint:
          if(branch.upstream == target,
            do: "Push and keep #{target} as the upstream.",
            else: "Push and set #{target} as the upstream."
          ),
        icon: "hero-cloud-arrow-up",
        action:
          {:push,
           [
             remote: remote.name,
             branch: branch.name,
             destination: branch.name,
             set_upstream: true
           ] ++ opts}
      }
    end)
  end

  defp force_confirmation(opts) do
    target = "#{opts[:remote]}/#{opts[:destination]}"

    %{
      title: "Force push #{opts[:branch]} to #{target}?",
      message:
        "#{target} is replaced by #{opts[:branch]} even if someone pushed to it since your " <>
          "last fetch. Their commits may be lost.",
      icon: "hero-exclamation-triangle",
      label: "Force push"
    }
  end

  def recovery(tab, %Error{args: ["push" | _]} = error) do
    # A retry keeps skipping hooks when the push that failed skipped them.
    carried = if "--no-verify" in error.args, do: [no_verify: true], else: []

    cond do
      error.message =~ "has no upstream branch" ->
        upstream_confirmation(tab, carried)

      error.message =~ "The upstream branch of your current branch does not match" ->
        mismatch_confirmation(tab, carried)

      true ->
        rejected_confirmation(tab, error, carried)
    end
  end

  def recovery(_tab, _error), do: nil

  # Only Git's porcelain rejection records qualify. Server policy, hooks,
  # authentication and transport errors must never suggest overriding history.
  defp rejected_confirmation(tab, error, carried) do
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
      opts = [remote: remote.name, branch: source, destination: destination] ++ carried

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

  defp mismatch_confirmation(tab, carried) do
    current = current_branch(tab)

    with %{upstream: upstream} when is_binary(upstream) <- current,
         remote when not is_nil(remote) <- upstream_remote(tab.remotes, upstream) do
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
            action:
              {:push,
               [remote: remote.name, branch: current.name, destination: destination] ++ carried}
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
               ] ++ carried}
          }
        ]
      }
    else
      _no_upstream -> nil
    end
  end

  defp current_branch(tab), do: Enum.find(tab.snapshot.branches, & &1.current?)

  # Remote names may hold a slash, so the longest matching name wins: the
  # upstream "team/a/main" belongs to the remote "team/a" rather than "team".
  defp upstream_remote(remotes, upstream) do
    remotes
    |> Enum.sort_by(&(-String.length(&1.name)))
    |> Enum.find(&String.starts_with?(upstream, &1.name <> "/"))
  end
end
