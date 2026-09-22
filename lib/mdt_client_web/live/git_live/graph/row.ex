defmodule MDTClientWeb.GitLive.Graph.Row do
  @moduledoc """
  One laid out commit: where its node sits and which edges cross its row.

  Every edge is `{from_lane, to_lane, color}`. `incoming` edges are drawn from
  the top of the row down to the node, `outgoing` from the node down to the
  bottom of the row, and `through` runs the full height for lanes that belong
  to unrelated branches.
  """

  alias MDTClient.Git.Commit

  @enforce_keys [:commit, :lane, :color]
  defstruct [:commit, :lane, :color, incoming: [], outgoing: [], through: []]

  @type edge :: {non_neg_integer(), non_neg_integer(), non_neg_integer()}

  @type t :: %__MODULE__{
          commit: Commit.t(),
          lane: non_neg_integer(),
          color: non_neg_integer(),
          incoming: [edge()],
          outgoing: [edge()],
          through: [edge()]
        }
end
