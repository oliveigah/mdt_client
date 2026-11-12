defmodule MDTClient.Sandbox.Approval do
  @moduledoc """
  A request or connection held until you decide, or until it gives up.

  `facts` are what MDT worked out from the traffic itself. `claims` are text
  the agent wrote, such as commit messages; they are shown apart and never
  taken as facts. `pattern` is what "allow similar" would let through.
  """

  @enforce_keys [:id, :grant_id, :kind, :title, :requested_at, :deadline]
  defstruct [
    :id,
    :grant_id,
    :kind,
    :title,
    :method,
    :host,
    :path,
    :pattern,
    :requested_at,
    :deadline,
    :decided_at,
    :decision,
    facts: [],
    claims: [],
    retries: 0,
    status: :waiting
  ]

  @type status :: :waiting | :allowed | :denied | :timed_out
  @type decision ::
          :allow_once | {:allow_for, pos_integer() | :grant} | :deny | :deny_and_turn_off

  @type t :: %__MODULE__{
          id: String.t(),
          grant_id: String.t(),
          kind: :request | :connection,
          title: String.t(),
          method: String.t() | nil,
          host: String.t(),
          path: String.t() | nil,
          pattern: String.t() | nil,
          requested_at: DateTime.t(),
          deadline: DateTime.t(),
          decided_at: DateTime.t() | nil,
          decision: decision() | nil,
          facts: [{String.t(), String.t()}],
          claims: [{String.t(), String.t()}],
          retries: non_neg_integer(),
          status: status()
        }
end
