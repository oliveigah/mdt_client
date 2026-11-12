defmodule MDTClient.Sandbox.Share do
  @moduledoc "A host folder mounted at the same path in the VM, read-write or read-only."

  @enforce_keys [:path, :mode]
  defstruct [:path, :mode]

  @type t :: %__MODULE__{path: String.t(), mode: :rw | :ro}
end
