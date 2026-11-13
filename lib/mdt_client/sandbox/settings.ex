defmodule MDTClient.Sandbox.Settings do
  @moduledoc """
  How the VM is built. Changing the image, resources or shared folders of a VM
  that exists means recreating it: microsandbox cannot change mounts live.
  `image_name` only names the next build. `host_notes` is your own text
  about this machine, which agents read with the rest of `mdt host`.

  Disk comes in two kinds. `disk_gib` sizes the VM's root disk, a sparse
  image that takes host space only as it fills and starts empty on every
  recreate. `write_budget_gib` is how much the VM may add to each folder it
  mounts read-write (Home, Cache, its memory, your shares) per boot; it
  keeps a runaway agent from filling your disk. microsandbox's own default
  is 4 GiB for both.
  """

  alias MDTClient.Sandbox.Share

  defstruct containerfile: nil,
            image_name: "mdt_agent_sdb_image",
            cpus: 4,
            memory_gib: 8,
            disk_gib: 64,
            write_budget_gib: 64,
            proxy_port: 18080,
            hold_seconds: 180,
            shares: [],
            optmem_path: nil,
            host_notes: ""

  @type t :: %__MODULE__{
          containerfile: String.t() | nil,
          image_name: String.t(),
          cpus: pos_integer(),
          memory_gib: pos_integer(),
          disk_gib: pos_integer(),
          write_budget_gib: pos_integer(),
          proxy_port: pos_integer(),
          hold_seconds: pos_integer(),
          shares: [Share.t()],
          optmem_path: String.t() | nil,
          host_notes: String.t()
        }
end
