defmodule MDTClient.Sandbox.HostGit do
  @moduledoc """
  git on one of your repositories, as the sandbox runs it for a project.

  Two things set it apart from the Git tool's own runner. It talks to a
  repository in the VM, so every object that arrives is checked
  (`fetch.fsckObjects`) and nothing follows submodules. And it never changes
  what is yours without being asked: it doesn't commit, and what it reads
  of your working tree it reads through a copy of the index (`snapshot/1`).

  What git prints can be the VM's to choose (a diff, file names, a remote's
  refusal), and so can its size. `run/3` reads at most `:max` bytes and
  fails past that, instead of taking gigabytes into MDT's memory, and
  `:file_limit` bounds what a fetch may write. What it reports as an error
  is text that shows all it holds (`MDTClient.Sandbox.Shown`); what it
  returns on success is git's own bytes, for the caller to read.
  """

  alias MDTClient.Sandbox.Shown

  @max_output 32 * 1024 * 1024

  @transport ~w(-c protocol.ext.allow=always -c fetch.fsckObjects=true -c transfer.fsckObjects=true -c fetch.recurseSubmodules=false)
  @identity [
    {"GIT_AUTHOR_NAME", "MDT"},
    {"GIT_AUTHOR_EMAIL", "mdt@localhost"},
    {"GIT_COMMITTER_NAME", "MDT"},
    {"GIT_COMMITTER_EMAIL", "mdt@localhost"}
  ]

  @doc """
  Runs git in `repo`. `{:ok, output}` when it exits 0.

  ## Options

    * `:env` - more environment variables
    * `:seconds` - how long it may take (120)
    * `:ok` - exit statuses that count as done ([0])
    * `:max` - how many bytes of output are read (32 MiB); more is an error
    * `:cut` - with `true`, more than `:max` is `{:cut, the_first_max_bytes}`
      instead of an error, for output that is only shown
    * `:file_limit` - the largest file git may write, in MiB; a fetch that
      brings more fails
  """
  @spec run(Path.t(), [String.t()], keyword()) ::
          {:ok, binary()} | {:cut, binary()} | {:error, String.t()}
  def run(repo, args, opts \\ []) do
    seconds = Keyword.get(opts, :seconds, 120)
    max = Keyword.get(opts, :max, @max_output)
    env = [{"GIT_TERMINAL_PROMPT", "0"} | Keyword.get(opts, :env, [])]

    limit =
      case Keyword.get(opts, :file_limit) do
        nil -> ""
        mib -> "ulimit -f #{mib * 1024}; "
      end

    # `head` stops reading one byte past the limit, which tells "more" from
    # "exactly that much", and git then ends on the closed pipe.
    script = ~s(set -o pipefail; #{limit}git "$@" 2>&1 | head -c #{max + 1})

    words =
      ["--kill-after=5", "#{seconds}", "bash", "-c", script, "git", "-C", repo] ++
        @transport ++ args

    case System.cmd("timeout", words, env: env) do
      {_output, 124} ->
        {:error, "git #{hd(args)} took longer than #{seconds} s"}

      {output, _status} when byte_size(output) > max ->
        if Keyword.get(opts, :cut, false),
          do: {:cut, binary_part(output, 0, max)},
          else: {:error, "git #{hd(args)} printed more than #{size(max)}"}

      {output, status} ->
        if status in Keyword.get(opts, :ok, [0]),
          do: {:ok, output},
          else: {:error, output |> String.trim() |> Shown.text()}
    end
  end

  defp size(bytes) when bytes >= 1024 * 1024, do: "#{div(bytes, 1024 * 1024)} MiB"
  defp size(bytes), do: "#{div(bytes, 1024)} KiB"

  @doc "The one line a git command prints, or nil when it fails or prints nothing."
  @spec line(Path.t(), [String.t()]) :: String.t() | nil
  def line(repo, args) do
    case run(repo, args) do
      {:ok, output} -> output |> String.trim() |> then(&if(&1 == "", do: nil, else: &1))
      {:error, _} -> nil
    end
  end

  @doc "The top folder of the repository `path` is in, or nil when it is in none."
  @spec top(Path.t()) :: Path.t() | nil
  def top(path), do: if(File.dir?(path), do: line(path, ["rev-parse", "--show-toplevel"]))

  @doc "The branch checked out, or nil when HEAD is detached."
  @spec branch(Path.t()) :: String.t() | nil
  def branch(repo), do: line(repo, ["symbolic-ref", "--quiet", "--short", "HEAD"])

  @doc """
  Your working tree as a commit on top of HEAD: tracked changes and new
  files, not ignored ones. It is made through a copy of the index, so your
  index, HEAD and files stay exactly as they were. With nothing changed, it
  is HEAD itself.

  `env` goes to every git run, as when the objects it makes go somewhere
  other than your repository (`MDTClient.Sandbox.PullStore.view/2`).
  """
  @spec snapshot(Path.t(), [{String.t(), String.t()}]) :: {:ok, String.t()} | {:error, String.t()}
  def snapshot(repo, env \\ []) do
    temporary = Path.join(System.tmp_dir!(), "mdt-index-#{System.unique_integer([:positive])}")
    outer = env
    env = [{"GIT_INDEX_FILE", temporary} | outer]

    try do
      with head when is_binary(head) <- line(repo, ["rev-parse", "--verify", "--quiet", "HEAD"]),
           index when is_binary(index) <- line(repo, ["rev-parse", "--git-path", "index"]),
           _ = File.cp(Path.expand(index, repo), temporary),
           {:ok, _} <- run(repo, ["add", "--all"], env: env),
           {:ok, tree} <- run(repo, ["write-tree"], env: env),
           tree = String.trim(tree),
           {:ok, head_tree} <- run(repo, ["rev-parse", "HEAD^{tree}"], env: outer) do
        if tree == String.trim(head_tree) do
          {:ok, head}
        else
          with {:ok, commit} <-
                 run(
                   repo,
                   ["commit-tree", tree, "-p", head, "-m", "Your working tree, as MDT read it"],
                   env: @identity ++ outer
                 ) do
            {:ok, String.trim(commit)}
          end
        end
      else
        nil -> {:error, "This repository has no commit yet."}
        {:error, message} -> {:error, message}
      end
    after
      File.rm(temporary)
    end
  end
end
