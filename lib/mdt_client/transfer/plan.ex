defmodule MDTClient.Transfer.Plan do
  @moduledoc """
  An export file that has been opened and checked, and what importing it
  would do.

  Every entry in `sections` has already been through its participant's
  `prepare/2`, so importing can no longer fail on what the file holds — only
  on writing it. `skipped` lists the sections no participant here recognises,
  such as ones written by a newer build; they are left out of the import.
  """

  @typedoc "A section ready to import."
  @type section :: %{
          participant: module(),
          key: String.t(),
          label: String.t(),
          summary: String.t(),
          data: MDTClient.Transfer.Participant.prepared()
        }

  @type t :: %__MODULE__{
          created_at: DateTime.t(),
          username: String.t(),
          app_version: String.t(),
          sections: [section()],
          skipped: [String.t()]
        }

  # The sections hold the decrypted data, which has no business in a crash
  # report or a log line.
  @derive {Inspect, except: [:sections]}
  defstruct [:created_at, :username, :app_version, sections: [], skipped: []]
end
