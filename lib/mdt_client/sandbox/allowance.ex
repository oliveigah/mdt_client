defmodule MDTClient.Sandbox.Allowance do
  @moduledoc """
  A temporary yes: requests like one you approved go through without asking
  until `until`, or until the grant turns off when `until` is nil.
  """

  @enforce_keys [:id, :pattern]
  defstruct [:id, :pattern, :until]

  @type t :: %__MODULE__{id: String.t(), pattern: String.t(), until: DateTime.t() | nil}
end
