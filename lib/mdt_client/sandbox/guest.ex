defmodule MDTClient.Sandbox.Guest do
  @moduledoc """
  Reaching into a VM from MDT: running a command there, and the address
  git uses for a repository there.

  Both go through `msb exec`, a pipe into the running VM. There is no
  network between MDT and the VM and no shared folder for projects, so this
  pipe is how a project's commits travel: git's own protocol runs through
  it, with `git upload-pack` or `git receive-pack` on the VM's end.
  `--stream` matters: plain `msb exec` holds the command's output until it
  ends, which stalls a protocol that talks both ways.

  A guest is a map, so tests can put a folder of this machine in the VM's
  place (`local/1`):

    * `root` - where projects live there (`/work`);
    * `exec` - runs a command, given as words, and returns its output;
    * `git_url` - the address of the repository at a path there, for
      `git push` and `git fetch` on this machine;
    * `env` - what git needs in its environment to use that address.
  """

  alias MDTClient.Sandbox.Msb

  @type t :: %{
          root: Path.t(),
          exec: ([String.t()] -> {:ok, String.t()} | {:error, String.t()}),
          git_url: (Path.t() -> String.t()),
          env: [{String.t(), String.t()}]
        }

  @doc "The running VM of an identity."
  @spec vm(String.t(), String.t()) :: t()
  def vm(username, name) do
    %{
      root: "/work",
      exec: fn words -> Msb.run(username, ["exec", name, "--" | words], 300) end,
      # git's `ext` transport: a command whose input and output carry the
      # protocol. `%s` becomes upload-pack or receive-pack.
      git_url: fn path ->
        "ext::" <>
          Enum.map_join(
            [Msb.executable() || "msb", "exec", "--stream", name, "--", "git", "%s", path],
            " ",
            &ext_word/1
          )
      end,
      env: Msb.env(username)
    }
  end

  @doc "A folder of this machine standing in for the VM's disk, for tests."
  @spec local(Path.t()) :: t()
  def local(root) do
    %{
      root: root,
      exec: fn [command | args] ->
        case System.cmd(command, args, stderr_to_stdout: true, env: git_env()) do
          {output, 0} -> {:ok, output}
          {output, _status} -> {:error, String.trim(output)}
        end
      end,
      git_url: fn path -> path end,
      env: []
    }
  end

  @doc "An environment in which git reads no configuration but the repository's own."
  @spec git_env() :: [{String.t(), String.t()}]
  def git_env, do: [{"GIT_CONFIG_GLOBAL", "/dev/null"}, {"GIT_CONFIG_NOSYSTEM", "1"}]

  # In an `ext::` address a space separates words and `%` starts an escape;
  # `% ` is a space inside a word. `%s` is left for git to fill in.
  defp ext_word("%s"), do: "%s"
  defp ext_word(word), do: word |> String.replace("%", "%%") |> String.replace(" ", "% ")
end
