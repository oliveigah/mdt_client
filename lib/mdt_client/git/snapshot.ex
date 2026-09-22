defmodule MDTClient.Git.Snapshot do
  @moduledoc "The repository state needed to populate the branch list and commit graph."

  alias MDTClient.Git.Branch
  alias MDTClient.Git.Commit
  alias MDTClient.Git.Operation
  alias MDTClient.Git.Repository

  @enforce_keys [:repository, :detached?, :branches, :commits]
  defstruct [
    :repository,
    :head,
    :current_branch,
    :operation,
    detached?: false,
    branches: [],
    commits: []
  ]

  @type t :: %__MODULE__{
          repository: Repository.t(),
          head: String.t() | nil,
          current_branch: String.t() | nil,
          operation: Operation.t() | nil,
          detached?: boolean(),
          branches: [Branch.t()],
          commits: [Commit.t()]
        }
end
