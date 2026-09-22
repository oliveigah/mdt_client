defmodule MDTClient.Git.Remote do
  @moduledoc "A configured Git remote and the transport used by its URLs."

  @enforce_keys [:name, :fetch_url, :push_url, :kind]
  defstruct [:name, :fetch_url, :push_url, :kind, :ssh_url]

  @type kind :: :ssh | :https | :http | :file | :other

  @type t :: %__MODULE__{
          name: String.t(),
          fetch_url: String.t(),
          push_url: String.t(),
          kind: kind(),
          ssh_url: String.t() | nil
        }
end
