defmodule MDTClient.Git.DiffLine do
  @moduledoc "One line of a unified diff, with the line numbers it belongs to."

  @enforce_keys [:kind, :text]
  defstruct [:kind, :text, :old_line, :new_line]

  @type kind :: :context | :added | :removed

  @type t :: %__MODULE__{
          kind: kind(),
          text: String.t(),
          old_line: pos_integer() | nil,
          new_line: pos_integer() | nil
        }
end
