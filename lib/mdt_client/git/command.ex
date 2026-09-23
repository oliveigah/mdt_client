defmodule MDTClient.Git.Command do
  @moduledoc false

  require Logger

  alias MDTClient.Git.Error
  alias MDTClient.Git.Repository

  @type capture_result :: {String.t(), non_neg_integer()} | {:system_error, Error.t()}

  @spec run(Repository.t(), [String.t()], keyword()) ::
          {:ok, String.t()} | {:error, Error.t()}
  def run(%Repository{} = repository, args, opts \\ []) do
    case capture(repository, args, opts) do
      {:system_error, error} -> {:error, error}
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, Error.command(args, status, output)}
    end
  end

  @spec capture(Repository.t(), [String.t()], keyword()) :: capture_result()
  def capture(%Repository{} = repository, args, opts \\ []) do
    capture_path(repository.path, args,
      ssh_key: repository.ssh_key,
      env: Keyword.get(opts, :env, [])
    )
  end

  @spec capture_path(Path.t(), [String.t()], keyword()) :: capture_result()
  def capture_path(path, args, opts \\ []) do
    started = System.monotonic_time(:millisecond)

    result =
      case System.find_executable("git") do
        nil ->
          {:system_error, Error.new(:git_not_found, "Git is not installed or is not on PATH")}

        executable ->
          env = command_env(Keyword.get(opts, :ssh_key), Keyword.get(opts, :env, []))

          try do
            System.cmd(executable, ["-C", path | args], stderr_to_stdout: true, env: env)
          rescue
            error in [ArgumentError, ErlangError] ->
              {:system_error,
               Error.new(:command_failed, "Could not start Git: #{Exception.message(error)}")}
          end
      end

    elapsed = System.monotonic_time(:millisecond) - started
    command = safe_command(args)

    case result do
      {:system_error, error} ->
        Logger.warning("git command failed command=#{command} kind=#{error.kind}",
          system: :git_gui
        )

      {_output, 0} ->
        Logger.debug("git command finished command=#{command} duration_ms=#{elapsed}",
          system: :git_gui
        )

      {_output, status} ->
        Logger.warning(
          "git command failed command=#{command} exit_status=#{status} duration_ms=#{elapsed}",
          system: :git_gui
        )
    end

    result
  end

  # A Git argument can be a URL with credentials, a file path or a commit
  # message. Only emit recognized command verbs; never write raw arguments.
  defp safe_command([verb | _])
       when verb in ~w(add branch check-ref-format checkout cherry-pick clone commit
                       commit-tree config diff diff-tree fetch for-each-ref log merge
                       merge-base pull push rebase remote reset restore rev-parse revert
                       rm show stash status switch symbolic-ref tag),
       do: verb

  defp safe_command(_args), do: "other"

  defp command_env(ssh_key, extra) do
    base = [
      {"GIT_TERMINAL_PROMPT", "0"},
      {"GIT_EDITOR", "true"},
      {"GIT_SEQUENCE_EDITOR", "true"},
      {"GIT_MERGE_AUTOEDIT", "no"}
    ]

    base =
      if ssh_key,
        do: [{"GIT_SSH_COMMAND", MDTClient.Git.SSHKey.command(ssh_key)} | base],
        else: base

    base
    |> Map.new()
    |> Map.merge(Map.new(extra))
    |> Map.to_list()
  end
end
