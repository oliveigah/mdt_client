defmodule MDTClient.Git.Repository do
  @moduledoc "An opened Git worktree and the process environment used for it."

  @enforce_keys [:path, :git_dir, :common_dir]
  defstruct [:path, :git_dir, :common_dir, :ssh_auth_sock]

  @type t :: %__MODULE__{
          path: Path.t(),
          git_dir: Path.t(),
          common_dir: Path.t(),
          ssh_auth_sock: String.t() | nil
        }
end
