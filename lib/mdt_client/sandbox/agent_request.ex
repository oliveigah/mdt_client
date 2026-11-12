defmodule MDTClient.Sandbox.AgentRequest do
  @moduledoc """
  An agent in the VM asking for access through the agent channel: either an
  existing grant by `grant_id`, or, when `grant_id` is nil, something you have
  not set up yet, described in `need`. The `reason` is the agent's own words.
  """

  @enforce_keys [:id, :agent, :minutes, :reason, :requested_at]
  defstruct [
    :id,
    :agent,
    :grant_id,
    :need,
    :minutes,
    :reason,
    :requested_at,
    :answered_at,
    status: :waiting
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          agent: String.t(),
          grant_id: String.t() | nil,
          need: String.t() | nil,
          minutes: pos_integer(),
          reason: String.t(),
          requested_at: DateTime.t(),
          answered_at: DateTime.t() | nil,
          status: :waiting | :granted | :declined
        }
end
