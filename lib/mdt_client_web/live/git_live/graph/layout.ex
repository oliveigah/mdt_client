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

  Stashes are not history, so they hang off it: each takes a row directly above
  the commit it was made on and links down into that commit's lane from a lane
  of its own, even when it is the only thing above the commit, so the branch
  keeps its straight line.

  The result depends only on its inputs, so the same history always produces
  the same picture.
  """

  alias MDTClient.Git.Commit
  alias MDTClient.Git.Stash
  alias MDTClientWeb.GitLive.Graph.Row

  @colors 8

  @enforce_keys [:rows, :lane_count]
  defstruct rows: [], lane_count: 0, pending: nil

  @type t :: %__MODULE__{
          rows: [Row.t()],
          lane_count: non_neg_integer(),
          pending: Row.t() | nil
        }

  @doc "The number of distinct lane colors the layout cycles through."
  @spec colors() :: pos_integer()
  def colors, do: @colors

  @doc """
  The row a dirty worktree occupies above the graph.

  It carries no commit and draws a single edge down into the lane of the commit
  the work sits on, so uncommitted work reads as the tip of the branch it will
  land on. That lane is only kept open through the rows in between when the
  layout was made with `pending:`; otherwise the edge points at the newest row.
  """
  @spec pending_row(t()) :: Row.t()
  def pending_row(%__MODULE__{pending: %Row{} = row}), do: row
  def pending_row(%__MODULE__{rows: []}), do: %Row{commit: nil, lane: 0, color: color(0)}

  def pending_row(%__MODULE__{rows: [newest | _rest]}) do
    %Row{
      commit: nil,
      lane: newest.lane,
      color: newest.color,
      outgoing: [{newest.lane, newest.lane, newest.color}]
    }
  end

  @doc """
  Lays out `commits`, which must already be in topological order, with
  `stashes` hanging off the commits they were made on.

  A stash whose commit is not among `commits` goes last, its link running off
  the bottom like that of a commit whose parents are past the window.

  ## Options

    * `:pending` - the id of the commit a dirty worktree sits on. Its lane is
      reserved from the very top, so the line from `pending_row/1` runs through
      every row above that commit instead of stopping short.
  """
  @spec layout([Commit.t()], [Stash.t()], keyword()) :: t()
  def layout(commits, stashes \\ [], opts \\ []) when is_list(commits) and is_list(stashes) do
    {seed, pending} =
      case Keyword.get(opts, :pending) do
        nil ->
          {[], nil}

        head ->
          {[head], %Row{commit: nil, lane: 0, color: color(0), outgoing: [{0, 0, color(0)}]}}
      end

    {rows, _lanes, lane_count} =
      commits
      |> interleave(stashes)
      |> Enum.reduce({[], seed, length(seed)}, fn node, {rows, lanes, lane_count} ->
        {row, next_lanes} = place(node, lanes)

        {[row | rows], next_lanes,
         Enum.max([lane_count, row.lane + 1, length(lanes), length(next_lanes)])}
      end)

    %__MODULE__{rows: Enum.reverse(rows), lane_count: lane_count, pending: pending}
  end

  # Newest stash first, which is the order Git lists them in, so stash@{0} sits
  # highest when several were made on one commit.
  defp interleave(commits, []), do: commits

  defp interleave(commits, stashes) do
    ids = MapSet.new(commits, & &1.id)
    {placed, orphans} = Enum.split_with(stashes, &MapSet.member?(ids, &1.parent))
    above = Enum.group_by(placed, & &1.parent)

    Enum.flat_map(commits, &(Map.get(above, &1.id, []) ++ [&1])) ++ orphans
  end

  # The commit's lane is settled before the stash takes one: when nothing above
  # expects the commit yet, it gets the lane it would have had with no stash at
  # all, and the stash moves over to the next free one.
  defp place(%Stash{} = stash, lanes) do
    {reserved, target} =
      case Enum.find_index(lanes, &(&1 == stash.parent)) do
        nil ->
          target = free_lane(lanes)
          {List.replace_at(pad(lanes, target), target, stash.parent), target}

        index ->
          {lanes, index}
      end

    lane = free_lane(reserved)

    row = %Row{
      commit: nil,
      stash: stash,
      lane: lane,
      color: color(target),
      outgoing: [{lane, target, color(target)}],
      through: for({id, index} <- Enum.with_index(lanes), id, do: {index, index, color(index)})
    }

    {row, trim(reserved)}
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
