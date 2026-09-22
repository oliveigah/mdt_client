defmodule MDTClientWeb.Tabs do
  @moduledoc """
  Ordering shared by the tools that keep their work in tabs.

  Dragging a tab pushes the identifiers in the order the reader dropped them
  into. Applying that order here rather than in the browser keeps the list on
  screen the one the LiveView knows about, and tolerates an order that has gone
  stale: identifiers it does not know are ignored, and tabs it does not mention
  keep their place at the end.
  """

  @doc "Sorts `tabs` to match `order`, a list of tab identifiers."
  @spec reorder([map()], [String.t()]) :: [map()]
  def reorder(tabs, order) when is_list(tabs) and is_list(order) do
    positions =
      order
      |> Enum.filter(&is_binary/1)
      |> Enum.with_index()
      |> Map.new()

    Enum.sort_by(tabs, &Map.get(positions, &1.id, map_size(positions)))
  end
end
