defmodule MDTClient.Transfer.Participant do
  @moduledoc """
  A system whose data can be exported from MDT and imported back into it.

  `MDTClient.Transfer` owns no data of its own. Every system that does
  implements this behaviour and is listed in `MDTClient.Transfer.participants/0`;
  an export then holds one section per participant, and importing hands each
  section back to the participant that wrote it.

  Importing runs in two phases so a bad file cannot leave an identity half
  imported. `prepare/2` runs for every section before anything is touched, and
  must not change any state: it checks the data, upgrades it from older
  versions and derives whatever the system keeps alongside it. Each section is
  then written by `merge/2` or `replace/2`, as the user chose.
  """

  @typedoc "Whatever `export/1` produces. Only its own participant ever reads it."
  @type data :: term()

  @typedoc "Whatever `prepare/2` produces, ready for `merge/2` or `replace/2`."
  @type prepared :: term()

  @doc """
  Names this participant's section in an export file.

  It is written into every export, so it must never change once shipped.
  """
  @callback key() :: String.t()

  @doc "What the section holds, as shown to people exporting and importing."
  @callback label() :: String.t()

  @doc """
  The version of the data `export/1` produces.

  Bump it whenever that shape changes, and teach `prepare/2` to read the
  versions before it. A file whose section is newer than this is refused,
  since this build cannot know what it holds.
  """
  @callback version() :: pos_integer()

  @doc "Everything this participant keeps for an identity."
  @callback export(username :: String.t()) :: {:ok, data()} | {:error, term()}

  @doc """
  Checks a section read from a file and readies it for importing.

  `version` is the one the section was exported with, never newer than
  `version/0`. The error is a sentence shown to the user.
  """
  @callback prepare(version :: pos_integer(), data()) :: {:ok, prepared()} | {:error, String.t()}

  @doc ~S'A short account of prepared data, such as "42 requests".'
  @callback describe(prepared()) :: String.t()

  @doc """
  Combines prepared data with everything this participant keeps for an identity.

  How the two are reconciled is the participant's own call — what counts as
  the same item, and which side wins where they differ — with two rules.
  Nothing the identity already has may be lost. And merging must be
  idempotent: importing the same file twice, or a file this identity
  exported itself, leaves things as they were after the first time.
  """
  @callback merge(username :: String.t(), prepared()) :: :ok | {:error, term()}

  @doc """
  Replaces everything this participant keeps for an identity with prepared data.

  Besides importing in replace mode, this is how a failed import is undone:
  what the participant held just before is put back through it.
  """
  @callback replace(username :: String.t(), prepared()) :: :ok | {:error, term()}
end
