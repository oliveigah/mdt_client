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

  def git!(path, args) do
    {output, status} = System.cmd("git", ["-C", path | args], stderr_to_stdout: true)
    assert status == 0, "git #{Enum.join(args, " ")} failed:\n#{output}"
    String.trim_trailing(output)
  end
end
