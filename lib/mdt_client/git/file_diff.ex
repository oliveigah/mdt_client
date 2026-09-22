defmodule MDTClient.Git.FileDiff do
  @moduledoc """
  The diff of one repository path, on one side of the index.

  `side` is `:unstaged` for the difference between the index and the working
  tree, and `:staged` for the difference between HEAD and the index. A diff with
  no hunks is either unchanged on that side, or `binary?`, which Git refuses to
  render as text. `truncated?` says the file changed more than the requested
  line budget and the tail was dropped.
  """

  alias MDTClient.Git.DiffHunk

  @enforce_keys [:path, :side]
  defstruct [:path, :side, hunks: [], binary?: false, truncated?: false]

  @type side :: :staged | :unstaged

  @type t :: %__MODULE__{
          path: Path.t(),
          side: side(),
          hunks: [DiffHunk.t()],
          binary?: boolean(),
          truncated?: boolean()
        }

  @doc "The number of added and removed lines across every hunk."
  @spec counts(t()) :: %{added: non_neg_integer(), removed: non_neg_integer()}
  def counts(%__MODULE__{hunks: hunks}) do
    hunks
    |> Enum.flat_map(& &1.lines)
    |> Enum.reduce(%{added: 0, removed: 0}, fn
      %{kind: :added}, counts -> %{counts | added: counts.added + 1}
      %{kind: :removed}, counts -> %{counts | removed: counts.removed + 1}
      _line, counts -> counts
    end)
  end
end
