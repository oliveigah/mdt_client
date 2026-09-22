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
end
