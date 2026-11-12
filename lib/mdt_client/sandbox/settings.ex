defmodule MDTClient.Sandbox.Settings do
  @moduledoc """
  How the VM is built. Changing the image, resources or shared folders of a VM
  that exists means recreating it: microsandbox cannot change mounts live.
  `image_name` only names the next build.
  """

  alias MDTClient.Sandbox.Share

  defstruct containerfile: nil,
            image_name: "mdt_agent_sdb_image",
            cpus: 4,
            memory_gib: 8,
            proxy_port: 18080,
            hold_seconds: 180,
            shares: [],
            optmem_path: nil

  @type t :: %__MODULE__{
          containerfile: String.t() | nil,
          image_name: String.t(),
          cpus: pos_integer(),
          memory_gib: pos_integer(),
          proxy_port: pos_integer(),
          hold_seconds: pos_integer(),
          shares: [Share.t()],
          optmem_path: String.t() | nil
        }
end
