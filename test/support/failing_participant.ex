defmodule MDTClient.Transfer.FailingParticipant do
  @moduledoc """
  A transfer participant that exports and prepares fine but cannot write.

  Listed after a real participant, it makes an import fail partway, which is
  what exercises putting the earlier sections back.
  """

  @behaviour MDTClient.Transfer.Participant

  @impl true
  def key, do: "test.failing"

  @impl true
  def label, do: "Failing section"

  @impl true
  def version, do: 1

  @impl true
  def export(_username), do: {:ok, :nothing}

  @impl true
  def prepare(1, data), do: {:ok, data}

  @impl true
  def describe(_prepared), do: "Nothing"

  @impl true
  def merge(_username, _prepared), do: {:error, "the disk is full"}

  @impl true
  def replace(_username, _prepared), do: {:error, "the disk is full"}
end
