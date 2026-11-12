defmodule MDTClient.Sandbox.Approval do
  @moduledoc """
  Something that waits for your decision, or until it gives up. Two types:

    * **activation** (`kind: :activation`) - an agent in the VM asks for a
      grant to be turned on (`grant_id`), or for access no grant gives yet
      (`need`). `minutes` is how long it asked for, `reason` its own words.
    * **use** - a request carrying a grant's placeholder (`kind: :request`),
      held by the proxy, or a connection through a network grant
      (`kind: :connection`).

  `facts` are what MDT worked out from the traffic itself. `claims` are text
  the agent wrote, such as commit messages; they are shown apart and never
  taken as facts. `pattern` is what "allow similar" would let through.
  `request` is the request exactly as MDT received it, kept in memory only,
  for the full view and copying (`MDTClient.Sandbox.RequestView`).
  """

  @enforce_keys [:id, :kind, :title, :requested_at, :deadline]
  defstruct [
    :id,
    :kind,
    :grant_id,
    :title,
    :method,
    :host,
    :path,
    :pattern,
    :request,
    :agent,
    :minutes,
    :need,
    :reason,
    :requested_at,
    :deadline,
    :decided_at,
    :decision,
    facts: [],
    claims: [],
    retries: 0,
    status: :waiting
  ]

  @type kind :: :activation | :request | :connection
  @type status :: :waiting | :allowed | :denied | :timed_out

  @typedoc "How long an allowance or a grant lasts: minutes, or while the grant stays on."
  @type duration :: pos_integer() | :grant | :until_off

  @type decision ::
          :allow_once
          | {:allow, :similar | :all, pos_integer() | :grant}
          | :deny
          | :deny_and_turn_off
          | {:turn_on, pos_integer() | :until_off, :ask | :all}
          | {:set_up, String.t()}
          | :decline
          | :grant_off

  @type request :: %{
          host: String.t(),
          method: String.t(),
          path: String.t(),
          headers: [{String.t(), String.t()}],
          body: binary()
        }

  @type t :: %__MODULE__{
          id: String.t(),
          kind: kind(),
          grant_id: String.t() | nil,
          title: String.t(),
          method: String.t() | nil,
          host: String.t() | nil,
          path: String.t() | nil,
          pattern: String.t() | nil,
          request: request() | nil,
          agent: String.t() | nil,
          minutes: pos_integer() | nil,
          need: String.t() | nil,
          reason: String.t() | nil,
          requested_at: DateTime.t(),
          deadline: DateTime.t(),
          decided_at: DateTime.t() | nil,
          decision: decision() | nil,
          facts: [{String.t(), String.t()}],
          claims: [{String.t(), String.t()}],
          retries: non_neg_integer(),
          status: status()
        }

  @doc "Whether this is a use of a grant (a request or a connection) rather than an activation."
  @spec use?(t()) :: boolean()
  def use?(%__MODULE__{kind: kind}), do: kind in [:request, :connection]
end
