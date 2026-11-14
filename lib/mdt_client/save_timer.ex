defmodule MDTClient.SaveTimer do
  @moduledoc """
  The timer a store sets to write its changes a moment after them, so that a
  burst of changes becomes one write.

  A store keeps the timer it set, and sets no other while it waits. A timer
  that fired without its `:flush` being handled must not count as waiting:
  it never will be handled. That happens in development. `gen_server` skips
  a message when it can't find the `handle_info/2` for it, as while the
  store's module is compiled again because its file changed under a running
  MDT. Accepting a handoff into MDT's own checkout does that. Kept, that
  timer would hold back every later write until the store stops.
  """

  @doc """
  `timer` while it is still to fire; else a new one, which sends `:flush`
  to this process in `ms`.
  """
  @spec ensure(reference() | nil, non_neg_integer()) :: reference()
  def ensure(timer, ms) do
    if waiting?(timer), do: timer, else: Process.send_after(self(), :flush, ms)
  end

  @doc """
  Whether a write is owed that `timer` won't make: it fired, and its
  `:flush` was lost, or is still on its way.
  """
  @spec lost?(reference() | nil) :: boolean()
  def lost?(timer), do: is_reference(timer) and not waiting?(timer)

  defp waiting?(timer), do: is_reference(timer) and Process.read_timer(timer) != false
end
