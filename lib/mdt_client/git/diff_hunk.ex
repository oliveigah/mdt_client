defmodule MDTClient.Git.DiffHunk do
  @moduledoc "A contiguous run of changed lines, as Git groups them."

  alias MDTClient.Git.DiffLine

  @enforce_keys [:header, :lines]
  defstruct [:header, :heading, :old_start, :new_start, lines: []]

  @type t :: %__MODULE__{
          header: String.t(),
          heading: String.t() | nil,
          old_start: pos_integer() | nil,
          new_start: pos_integer() | nil,
          lines: [DiffLine.t()]
        }
end
