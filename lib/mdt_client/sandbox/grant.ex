defmodule MDTClient.Sandbox.Grant do
  @moduledoc """
  One credential or one piece of network access the VM can be given, and
  taken back from, on the spot.

  The `kind` decides what the VM holds:

    * `:http` - a placeholder; MDT swaps the real value in on the way out
    * `:network` - reachability to `destinations`; nothing to hold
    * `:file` - the real value, as a file; copies outlive turning it off

  See `docs/agent_sandbox.md` for the whole model.
  """

  alias MDTClient.Sandbox.{Allowance, Rule}

  @enforce_keys [:id, :name, :recipe, :kind]
  defstruct [
    :id,
    :name,
    :recipe,
    :kind,
    :expires_at,
    :placeholder,
    :path,
    :last_used_at,
    state: :off,
    source: :stored,
    env: [],
    hosts: [],
    carriers: [],
    destinations: [],
    per_connection: :ask,
    rules: [],
    default_action: :ask,
    allowances: [],
    uses: 0
  ]

  @type kind :: :http | :network | :file
  @type source :: :stored | {:minted, String.t()}

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          recipe: atom(),
          kind: kind(),
          state: :on | :off,
          expires_at: DateTime.t() | nil,
          placeholder: String.t() | nil,
          path: String.t() | nil,
          last_used_at: DateTime.t() | nil,
          source: source(),
          env: [String.t()],
          hosts: [String.t()],
          carriers: [String.t()],
          destinations: [String.t()],
          per_connection: :allow | :ask,
          rules: [Rule.t()],
          default_action: Rule.action(),
          allowances: [Allowance.t()],
          uses: non_neg_integer()
        }

  @doc "Whether the VM ends up holding the real value, which no switch can take back."
  @spec exposes_value?(t()) :: boolean()
  def exposes_value?(%__MODULE__{kind: kind}), do: kind == :file

  @doc "Whether the grant is on right now."
  @spec on?(t()) :: boolean()
  def on?(%__MODULE__{state: state}), do: state == :on
end
