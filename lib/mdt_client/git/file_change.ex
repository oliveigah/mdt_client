defmodule MDTClient.Git.FileChange do
  @moduledoc """
  One repository path Git reports as changed.

  `staged` describes the difference between HEAD and the index, `unstaged` the
  difference between the index and the working tree. Either is `nil` when that
  side has no change, so a path can appear in the staged list, the unstaged
  list, or both. Untracked and conflicted paths are flagged separately because
  they need different actions from the UI.
  """

  @enforce_keys [:path]
  defstruct [:path, :original_path, :staged, :unstaged, conflicted?: false, untracked?: false]

  @type state ::
          :added
          | :modified
          | :deleted
          | :renamed
          | :copied
          | :type_changed
          | :untracked
          | :conflicted

  @type t :: %__MODULE__{
          path: Path.t(),
          original_path: Path.t() | nil,
          staged: state() | nil,
          unstaged: state() | nil,
          conflicted?: boolean(),
          untracked?: boolean()
        }

  @doc "Whether the index differs from HEAD for this path."
  @spec staged?(t()) :: boolean()
  def staged?(%__MODULE__{staged: staged}), do: not is_nil(staged)

  @doc "Whether the working tree differs from the index for this path."
  @spec unstaged?(t()) :: boolean()
  def unstaged?(%__MODULE__{unstaged: unstaged}), do: not is_nil(unstaged)
end
