defmodule MDTClient.Git.Branch do
  @moduledoc "A local or remote branch reference."

  @enforce_keys [:name, :full_name, :kind, :target]
  defstruct [
    :name,
    :full_name,
    :kind,
    :target,
    :upstream,
    :remote,
    :symbolic_target,
    current?: false,
    ahead: 0,
    behind: 0
  ]

  @type kind :: :local | :remote

  @type t :: %__MODULE__{
          name: String.t(),
          full_name: String.t(),
          kind: kind(),
          target: String.t(),
          upstream: String.t() | nil,
          remote: String.t() | nil,
          symbolic_target: String.t() | nil,
          current?: boolean(),
          ahead: non_neg_integer(),
          behind: non_neg_integer()
        }

  @doc """
  The local branch that tracks the remote branch named `remote`, if any.

  When several do, the checked-out one wins, then the one named like the remote
  branch without its remote, as `origin/feature` would be checked out as.
  """
  @spec tracking([t()], String.t()) :: t() | nil
  def tracking(branches, remote) when is_list(branches) and is_binary(remote) do
    own_name = remote |> String.split("/", parts: 2) |> List.last()

    branches
    |> Enum.filter(&(&1.kind == :local and &1.upstream == remote))
    |> Enum.sort_by(&{not &1.current?, &1.name != own_name, &1.name})
    |> List.first()
  end
end
