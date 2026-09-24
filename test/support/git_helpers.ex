defmodule MDTClient.GitHelpers do
  @moduledoc false

  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [on_exit: 1]

  alias MDTClient.Git.Core

  def initialized_repository(_context) do
    base =
      Path.join(
        System.tmp_dir!(),
        "mdt-git-test-#{System.unique_integer([:positive, :monotonic])}"
      )

    path = Path.join(base, "worktree")
    File.mkdir_p!(path)

    git!(path, ["init", "--initial-branch=main"])
    git!(path, ["config", "user.name", "MDT Test"])
    git!(path, ["config", "user.email", "mdt@example.test"])

    File.write!(Path.join(path, "README.md"), "initial\n")
    git!(path, ["add", "README.md"])
    git!(path, ["commit", "-m", "initial commit"])

    on_exit(fn -> File.rm_rf!(base) end)

    {:ok, repository} = Core.open(path)

    %{
      base: base,
      path: path,
      repository: repository,
      initial_commit: git!(path, ["rev-parse", "HEAD"])
    }
  end

  def commit_file(path, filename, contents, message) do
    File.write!(Path.join(path, filename), contents)
    git!(path, ["add", "--", filename])
    git!(path, ["commit", "-m", message])
    git!(path, ["rev-parse", "HEAD"])
  end

  def empty_commits(path, count) do
    for index <- 1..count do
      git!(path, ["commit", "--allow-empty", "--quiet", "-m", "empty #{index}"])
    end

    git!(path, ["rev-parse", "HEAD"])
  end

  def ssh_key_pair(base, name \\ "id_ed25519") do
    private_key = Path.join(base, name)
    executable = System.find_executable("ssh-keygen")
    assert executable, "ssh-keygen is required by the Git SSH tests"

    {output, status} =
      System.cmd(executable, ["-q", "-t", "ed25519", "-N", "", "-f", private_key],
        stderr_to_stdout: true
      )

    assert status == 0, "ssh-keygen failed:\n#{output}"
    {private_key, private_key <> ".pub"}
  end

  def git!(path, args) do
    {output, status} = System.cmd("git", ["-C", path | args], stderr_to_stdout: true)
    assert status == 0, "git #{Enum.join(args, " ")} failed:\n#{output}"
    String.trim_trailing(output)
  end
end
