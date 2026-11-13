defmodule MDTClient.Sandbox.Sync do
  @moduledoc """
  Your work into the VM: the one direction a sync goes.

  Your local branches arrive in the project's copy as `host/<branch>`. Only
  committed work goes, unless you ask for what you haven't committed too:
  that travels as a snapshot (`MDTClient.Sandbox.HostGit.snapshot/1`), to
  `host-wip/<branch>`.

  The copy itself follows the branch you have checked out. It starts on
  that branch, and each sync fast-forwards it when it is clean and only
  behind; git does that part itself, in the VM
  (`receive.denyCurrentBranch=updateInstead`). A copy with changes or
  commits of its own is left alone, and the result says so.

  Nothing comes back: a sync writes nothing on your machine.
  """

  alias MDTClient.Sandbox.{Guest, HostGit, Project, Shown}

  @type followed :: :updated | :current | {:left, String.t()} | :none
  @type result :: %{branch: String.t() | nil, followed: followed(), uncommitted: boolean()}

  # Makes the copy where there is none, on the branch you have, and lets a
  # push update its checkout when that is safe.
  @prepare """
  set -e
  if [ ! -d "$1/.git" ]; then
    mkdir -p "$(dirname "$1")"
    if [ -n "$2" ]; then git init -q -b "$2" "$1"; else git init -q "$1"; fi
  fi
  git -C "$1" config receive.denyCurrentBranch updateInstead
  """

  @doc """
  Syncs `project` into the VM behind `guest`.

  ## Options

    * `:uncommitted` - also send your working tree as it is (false)
  """
  @spec run(Project.t(), Guest.t(), keyword()) :: {:ok, result()} | {:error, String.t()}
  def run(%Project{path: repo} = project, guest, opts \\ []) do
    copy = Project.guest_path(project, guest)
    branch = HostGit.branch(repo)

    with {:ok, _} <- guest.exec.(["sh", "-c", @prepare, "mdt-sync", copy, branch || ""]),
         {:ok, snapshot} <- snapshot(repo, branch, Keyword.get(opts, :uncommitted, false)),
         specs = specs(branch, snapshot),
         # A branch the copy wouldn't follow makes git exit 1 with the rest
         # of the push done; the report says which.
         {:ok, report} <-
           HostGit.run(repo, ["push", "--porcelain", "--prune", guest.git_url.(copy) | specs],
             env: guest.env,
             ok: [0, 1],
             seconds: 600
           ),
         :ok <- pushed(report) do
      {:ok,
       %{
         branch: branch,
         followed: if(branch, do: followed(report, branch), else: :none),
         uncommitted: snapshot != nil
       }}
    end
  end

  defp snapshot(_repo, nil, _uncommitted?), do: {:ok, nil}
  defp snapshot(_repo, _branch, false), do: {:ok, nil}

  defp snapshot(repo, _branch, true) do
    with {:ok, commit} <- HostGit.snapshot(repo) do
      # Nothing uncommitted: the snapshot is HEAD, which the branch carries.
      if commit == HostGit.line(repo, ["rev-parse", "HEAD"]), do: {:ok, nil}, else: {:ok, commit}
    end
  end

  # Every branch as host/<branch>, pruned with yours; the branch you are on
  # into the copy's own, which only a fast-forward of a clean checkout
  # takes; the snapshot, forced, since each replaces the last.
  defp specs(branch, snapshot) do
    ["+refs/heads/*:refs/remotes/host/*"] ++
      if(branch, do: ["refs/heads/#{branch}:refs/heads/#{branch}"], else: []) ++
      if(snapshot, do: ["+#{snapshot}:refs/remotes/host-wip/#{branch}"], else: [])
  end

  # `git push --porcelain` prints one line per ref: a flag, a tab, from:to,
  # a tab, what happened. Without any, the push itself failed.
  defp lines(report) do
    for line <- String.split(report, "\n"),
        [flag, refs, summary] <- [String.split(line, "\t", parts: 3)],
        do: {flag, refs, summary}
  end

  defp pushed(report) do
    if Enum.any?(lines(report), fn {_flag, refs, _} ->
         String.contains?(refs, ":refs/remotes/host/")
       end),
       do: :ok,
       else: {:error, report |> String.trim() |> Shown.text()}
  end

  defp followed(report, branch) do
    wanted = "refs/heads/#{branch}:refs/heads/#{branch}"

    case Enum.find(lines(report), fn {_flag, refs, _} -> refs == wanted end) do
      {"=", _, _} -> :current
      {"!", _, summary} -> {:left, reason(summary)}
      {_updated, _, _} -> :updated
      nil -> :none
    end
  end

  defp reason(summary) do
    cond do
      summary =~ "unstaged changes" or summary =~ "uncommitted changes" or
          summary =~ "Working directory" ->
        "It has changes that aren't committed."

      summary =~ "fetch first" or summary =~ "non-fast-forward" ->
        "It has commits of its own."

      true ->
        # The other side's words: git in the VM wrote them.
        summary
        |> String.trim()
        |> String.trim_leading("[remote rejected] ")
        |> String.trim_leading("[rejected] ")
        |> Shown.text()
    end
  end
end
