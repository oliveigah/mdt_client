defmodule MDTClient.Git.Command do
  @moduledoc false

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
      ssh_auth_sock: repository.ssh_auth_sock,
      env: Keyword.get(opts, :env, [])
    )
  end

  @spec capture_path(Path.t(), [String.t()], keyword()) :: capture_result()
  def capture_path(path, args, opts \\ []) do
    case System.find_executable("git") do
      nil ->
        {:system_error, Error.new(:git_not_found, "Git is not installed or is not on PATH")}

      executable ->
        env = command_env(Keyword.get(opts, :ssh_auth_sock), Keyword.get(opts, :env, []))

        try do
          System.cmd(executable, ["-C", path | args], stderr_to_stdout: true, env: env)
        rescue
          error in [ArgumentError, ErlangError] ->
            {:system_error,
             Error.new(:command_failed, "Could not start Git: #{Exception.message(error)}")}
        end
    end
  end

  defp command_env(ssh_auth_sock, extra) do
    base = [
      {"GIT_TERMINAL_PROMPT", "0"},
      {"GIT_EDITOR", "true"},
      {"GIT_SEQUENCE_EDITOR", "true"},
      {"GIT_MERGE_AUTOEDIT", "no"}
    ]

    base =
      if is_binary(ssh_auth_sock) do
        [{"SSH_AUTH_SOCK", ssh_auth_sock} | base]
      else
        base
      end

    base
    |> Map.new()
    |> Map.merge(Map.new(extra))
    |> Map.to_list()
  end
end
