defmodule MDTClient.Sandbox.VM do
  @moduledoc """
  The VM's state as the control panel shows it.

  `exists?` says whether microsandbox has the VM at all; a VM is only
  created once its image is built. `stale?` is set when settings changed after
  the VM was created, so it runs with the old ones until it is recreated.
  `error` is the last thing `msb` refused, in its own words.
  """

  defstruct name: "agentbox",
            status: :stopped,
            started_at: nil,
            exists?: false,
            stale?: false,
            busy: nil,
            error: nil,
            msb: nil

  @type status :: :stopped | :starting | :running | :stopping | :crashed

  @type t :: %__MODULE__{
          name: String.t(),
          status: status(),
          started_at: DateTime.t() | nil,
          exists?: boolean(),
          stale?: boolean(),
          busy: String.t() | nil,
          error: String.t() | nil,
          msb: String.t() | nil
        }
end
