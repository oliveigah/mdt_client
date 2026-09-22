defmodule MDTClientWeb.GitLive.Graph.Layout do
  @moduledoc """
  Turns a topologically ordered commit list into drawable graph rows.

  The backend only describes topology, through each commit's ordered `parents`
  list, so lanes and edges are computed here. The algorithm walks the commits
  once, keeping a list of lanes where each slot holds the commit id that lane is
  waiting for:

    * a commit takes the lane that was reserved for it, or the leftmost free
      lane when nothing points at it yet (a branch tip or a new root);
    * its first parent continues in the same lane, which keeps a straight line
      down a branch;
    * further parents reuse the lane already reserved for them, or the leftmost
      free one, which is what makes merges fan out and rejoin;
    * lanes are never renumbered mid graph, so a line never jumps sideways
      without an edge explaining it.

  The result depends only on the commit list, so the same history always
  produces the same picture.
  """

  alias MDTClient.Git.Commit
  alias MDTClientWeb.GitLive.Graph.Row

  @colors 8

  @enforce_keys [:rows, :lane_count]
  defstruct rows: [], lane_count: 0

  @type t :: %__MODULE__{rows: [Row.t()], lane_count: non_neg_integer()}

  @doc "The number of distinct lane colors the layout cycles through."
  @spec colors() :: pos_integer()
  def colors, do: @colors

  @doc "Lays out `commits`, which must already be in topological order."
  @spec layout([Commit.t()]) :: t()
  def layout(commits) when is_list(commits) do
    {rows, _lanes, lane_count} =
      Enum.reduce(commits, {[], [], 0}, fn commit, {rows, lanes, lane_count} ->
        {row, next_lanes} = place(commit, lanes)

        {[row | rows], next_lanes,
         Enum.max([lane_count, row.lane + 1, length(lanes), length(next_lanes)])}
      end)

    %__MODULE__{rows: Enum.reverse(rows), lane_count: lane_count}
  end

  defp place(%Commit{} = commit, lanes) do
    claimed = for {id, index} <- Enum.with_index(lanes), id == commit.id, do: index
    lane = List.first(claimed) || free_lane(lanes)

    # Lanes that were waiting for this commit are consumed by it; the commit's
    # own lane is only kept when one of its parents continues in it.
    cleared =
      Enum.reduce([lane | claimed], pad(lanes, lane), fn index, acc ->
        List.replace_at(acc, index, nil)
      end)

    {reserved, outgoing} =
      commit.parents
      |> Enum.with_index()
      |> Enum.reduce({cleared, []}, fn {parent, position}, {acc, edges} ->
        target = parent_lane(acc, parent, lane, position)

        {List.replace_at(pad(acc, target), target, parent),
         [{lane, target, color(target)} | edges]}
      end)

    through =
      for {id, index} <- Enum.with_index(lanes),
          not is_nil(id),
          index != lane,
          index not in claimed,
          do: {index, index, color(index)}

    row = %Row{
      commit: commit,
      lane: lane,
      color: color(lane),
      incoming: for(index <- claimed, do: {index, lane, color(index)}),
      outgoing: Enum.reverse(outgoing),
      through: through
    }

    {row, trim(reserved)}
  end

  # The first parent stays in the commit's lane so branches read as straight
  # lines; any parent already expected somewhere keeps that lane so the two
  # sides of a merge rejoin instead of duplicating.
  defp parent_lane(lanes, parent, lane, position) do
    cond do
      index = Enum.find_index(lanes, &(&1 == parent)) -> index
      position == 0 -> lane
      true -> free_lane(lanes)
    end
  end

  defp free_lane(lanes) do
    Enum.find_index(lanes, &is_nil/1) || length(lanes)
  end

  defp pad(lanes, index) when length(lanes) > index, do: lanes
  defp pad(lanes, index), do: lanes ++ List.duplicate(nil, index - length(lanes) + 1)

  defp trim(lanes) do
    lanes
    |> Enum.reverse()
    |> Enum.drop_while(&is_nil/1)
    |> Enum.reverse()
  end

  defp color(lane), do: rem(lane, @colors)
end
