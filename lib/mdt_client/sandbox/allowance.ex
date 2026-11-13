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

  @doc """
  Whether this allowance covers a use with this pattern at `now`. One past
  its `until` covers nothing: the clock decides, not a timer, so an
  allowance also ends across a restart or a suspend.
  """
  @spec covers?(t(), String.t(), DateTime.t()) :: boolean()
  def covers?(%__MODULE__{} = allowance, pattern, now \\ DateTime.utc_now()) do
    not ended?(allowance, now) and allowance.pattern in [:all, pattern]
  end

  @doc "Whether the allowance's time has run out at `now`."
  @spec ended?(t(), DateTime.t()) :: boolean()
  def ended?(allowance, now \\ DateTime.utc_now())
  def ended?(%__MODULE__{until: nil}, _now), do: false
  def ended?(%__MODULE__{until: until}, now), do: DateTime.compare(now, until) != :lt

  @doc false
  def upgrade(%{} = saved), do: struct(__MODULE__, Map.delete(saved, :__struct__))
end
