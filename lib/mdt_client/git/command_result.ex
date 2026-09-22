defmodule MDTClient.Git.CommandResult do
  @moduledoc "The successful result of a mutating Git operation."

  @enforce_keys [:action, :output]
  defstruct [:action, :output]

  @type t :: %__MODULE__{action: atom(), output: String.t()}
end
