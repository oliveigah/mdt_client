defmodule MDTClient.Git.Stash do
  @moduledoc "A stash entry available for inspection, application, or removal."

  @enforce_keys [:index, :reference, :commit, :summary, :created_at]
  defstruct [:index, :reference, :commit, :summary, :created_at]

  @type t :: %__MODULE__{
          index: non_neg_integer(),
          reference: String.t(),
          commit: String.t(),
          summary: String.t(),
          created_at: DateTime.t()
        }
end
