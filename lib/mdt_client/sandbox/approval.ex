defmodule MDTClient.Sandbox.Approval do
  @moduledoc """
  Something that waits for your decision, or until it gives up. Three types:

    * **activation** (`kind: :activation`) - an agent in the VM asks for a
      grant to be turned on (`grant_id`), or for access no grant gives yet
      (`need`). `minutes` is how long it asked for, `reason` its own words.
    * **use** - a request carrying a grant's placeholder (`kind: :request`),
      held by the proxy, or a connection through a network grant
      (`kind: :connection`).
    * **command** (`kind: :command`) - an agent asks to run `script` on the
      host, in `dir`, for at most `timeout` seconds. It waits twice when you
      choose to see the output first: for your go-ahead (`stage: :run`), and
      once it ran, for you to release the output (`stage: :output`). `run`
      holds how the run went (`t:run/0`).

  `facts` are what MDT worked out itself. `claims` are text the agent wrote,
  such as commit messages; they are shown apart and never taken as facts.
  `hints` (commands only) are what MDT guessed from a command's text, shown
  as hints. `pattern` is what "allow similar" would let through, or what a
  second identical ask joins. `request` is the request exactly as MDT
  received it, kept in memory only, for the full view and copying
  (`MDTClient.Sandbox.RequestView`).
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
    :script,
    :dir,
    :timeout,
    :run,
    :requested_at,
    :deadline,
    :decided_at,
    :decision,
    stage: :run,
    facts: [],
    claims: [],
    hints: [],
    retries: 0,
    status: :waiting
  ]

  @type kind :: :activation | :request | :connection | :command
  @type status :: :waiting | :allowed | :denied | :timed_out

  @typedoc "How long an allowance or a grant lasts: minutes, or while the grant stays on."
  @type duration :: pos_integer() | :grant | :until_off

  @typedoc "Where a command's output goes when it ends: back to the agent, or to you first."
  @type output :: :send | :review

  @type decision ::
          :allow_once
          | {:allow, :similar | :all, pos_integer() | :grant}
          | :deny
          | :deny_and_turn_off
          | {:turn_on, pos_integer() | :until_off, :ask | :all}
          | {:set_up, String.t()}
          | :decline
          | :grant_off
          | {:run, output()}
          | :send_output
          | :keep_output

  @type request :: %{
          host: String.t(),
          method: String.t(),
          path: String.t(),
          headers: [{String.t(), String.t()}],
          body: binary()
        }

  @typedoc """
  A command's run: `:running` until it ends, then `:done` with its `exit`
  status and `output` (the first and last 32 KiB; `cut` bytes between them
  were dropped). `stopped` is set when you stopped it, `timed_out` when it
  hit its limit. `output_to` is where the output goes.
  """
  @type run :: %{
          state: :running | :done,
          output_to: output(),
          started_at: DateTime.t(),
          finished_at: DateTime.t() | nil,
          exit: integer() | nil,
          output: binary(),
          bytes: non_neg_integer(),
          cut: non_neg_integer(),
          stopped: boolean(),
          timed_out: boolean(),
          error: String.t() | nil
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
          script: String.t() | nil,
          dir: String.t() | nil,
          timeout: pos_integer() | nil,
          run: run() | nil,
          stage: :run | :output,
          requested_at: DateTime.t(),
          deadline: DateTime.t(),
          decided_at: DateTime.t() | nil,
          decision: decision() | nil,
          facts: [{String.t(), String.t()}],
          claims: [{String.t(), String.t()}],
          hints: [String.t()],
          retries: non_neg_integer(),
          status: status()
        }

  @doc "Whether this is a use of a grant (a request or a connection) rather than an ask."
  @spec use?(t()) :: boolean()
  def use?(%__MODULE__{kind: kind}), do: kind in [:request, :connection]

  @doc "Whether this is a command still running on the host."
  @spec running?(t()) :: boolean()
  def running?(%__MODULE__{kind: :command, run: %{state: :running}}), do: true
  def running?(%__MODULE__{}), do: false

  @doc """
  Whether the agent that asked has its final answer. For a command that ran,
  that is once its output may go back, or was kept; for everything else,
  once you decided or it gave up.
  """
  @spec final?(t()) :: boolean()
  def final?(%__MODULE__{status: :waiting}), do: false

  def final?(%__MODULE__{kind: :command, status: :allowed, run: %{state: :running}}),
    do: false

  def final?(%__MODULE__{}), do: true
end
