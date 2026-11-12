defmodule MDTClient.Sandbox.Allowance do
  @moduledoc """
  A standing yes on one grant: uses it covers go through without asking,
  until `until`, or until the grant turns off when `until` is nil.

  `pattern` is what it covers:

    * `:all` - every use of the grant;
    * a string - uses like one you approved: the same method and endpoint
      (`MDTClient.Sandbox.Describe`), or the same address and port for a
      connection.
  """

  @enforce_keys [:id, :pattern]
  defstruct [:id, :pattern, :until]

  @type t :: %__MODULE__{id: String.t(), pattern: String.t() | :all, until: DateTime.t() | nil}

  @doc "Whether this allowance covers a use with this pattern."
  @spec covers?(t(), String.t()) :: boolean()
  def covers?(%__MODULE__{pattern: :all}, _pattern), do: true
  def covers?(%__MODULE__{pattern: pattern}, pattern), do: true
  def covers?(%__MODULE__{}, _pattern), do: false

  @doc false
  def upgrade(%{} = saved), do: struct(__MODULE__, Map.delete(saved, :__struct__))
end
