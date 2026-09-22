defmodule MDTClient.Git.Operation do
  @moduledoc "A merge or history operation currently in progress in a worktree."

  @enforce_keys [:kind]
  defstruct [:kind, :original_head, :message, targets: [], current: nil, total: nil]

  @type kind :: :merge | :rebase | :cherry_pick | :revert | :bisect

  @type t :: %__MODULE__{
          kind: kind(),
          original_head: String.t() | nil,
          message: String.t() | nil,
          targets: [String.t()],
          current: pos_integer() | nil,
          total: pos_integer() | nil
        }
end
