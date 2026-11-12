defmodule MDTClient.Sandbox.Snapshot do
  @moduledoc """
  A copy of the VM's Home, taken before it was recreated. `tag` is the image
  tag the VM ran then, so going back to that tag can bring this Home back.
  """

  @enforce_keys [:id, :taken_at]
  defstruct [:id, :tag, :taken_at]

  @type t :: %__MODULE__{id: String.t(), tag: String.t() | nil, taken_at: DateTime.t()}
end
