defmodule MDTClient.Sandbox.Event do
  @moduledoc """
  One line of the activity log. It never holds a real credential value.

  `outcome` says what happened:

    * `:tunnel` - passed through as bytes, unread
    * `:swapped` - a placeholder was swapped for the real value
    * `:allowed`, `:denied`, `:timed_out` - an approval was decided or gave up
    * `:refused` - a placeholder arrived while its grant was off
    * `:blocked` - a destination MDT always refuses, or a network grant is off
    * `:violation` - a placeholder headed for a host its grant does not list
    * `:grant` - a grant was turned on or off
    * `:vm` - the VM started, stopped or was recreated
  """

  @enforce_keys [:id, :at, :outcome, :summary]
  defstruct [
    :id,
    :at,
    :outcome,
    :summary,
    :grant_id,
    :host,
    :port,
    :method,
    :path,
    :up,
    :down,
    :ms
  ]

  @type outcome ::
          :tunnel
          | :swapped
          | :allowed
          | :denied
          | :timed_out
          | :refused
          | :blocked
          | :violation
          | :grant
          | :vm

  @type t :: %__MODULE__{
          id: String.t(),
          at: DateTime.t(),
          outcome: outcome(),
          summary: String.t(),
          grant_id: String.t() | nil,
          host: String.t() | nil,
          port: non_neg_integer() | nil,
          method: String.t() | nil,
          path: String.t() | nil,
          up: non_neg_integer() | nil,
          down: non_neg_integer() | nil,
          ms: non_neg_integer() | nil
        }

  @groups %{
    "traffic" => [:tunnel],
    "credentials" => [:swapped, :allowed, :denied, :timed_out, :refused],
    "blocked" => [:blocked, :violation],
    "changes" => [:grant, :vm]
  }

  @doc "The filter groups the activity page offers, and the outcomes in each."
  @spec groups() :: %{String.t() => [outcome()]}
  def groups, do: @groups

  @doc """
  Whether `event` passes the activity filters: `:group` (a key of `groups/0`,
  or `"all"`), `:grant` (an id, or `""`) and `:q` (words to look for).
  """
  @spec matches?(t(), map()) :: boolean()
  def matches?(%__MODULE__{} = event, filters) do
    outcomes = Map.get(@groups, Map.get(filters, :group, "all"))
    grant = Map.get(filters, :grant, "")
    term = filters |> Map.get(:q, "") |> String.trim() |> String.downcase()

    (is_nil(outcomes) or event.outcome in outcomes) and
      (grant == "" or event.grant_id == grant) and
      (term == "" or
         [event.summary, event.host, event.path, event.method]
         |> Enum.join(" ")
         |> String.downcase()
         |> String.contains?(term))
  end
end
