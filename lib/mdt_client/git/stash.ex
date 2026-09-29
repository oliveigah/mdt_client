defmodule MDTClient.Git.Stash do
  @moduledoc """
  A stash entry available for inspection, application, or removal.

  `parent` is the commit the stash was made on, which is where the graph links
  it. Git records a stash as a merge of that commit with one holding the index
  and, when untracked files were included, a third holding those; `untracked?`
  says whether that third one exists.
  """

  @enforce_keys [:index, :reference, :commit, :parent, :summary, :created_at]
  defstruct [:index, :reference, :commit, :parent, :summary, :created_at, untracked?: false]

  @type t :: %__MODULE__{
          index: non_neg_integer(),
          reference: String.t(),
          commit: String.t(),
          parent: String.t(),
          summary: String.t(),
          created_at: DateTime.t(),
          untracked?: boolean()
        }
end
