defmodule MDTClient.Sandbox.Rule do
  @moduledoc """
  One line of a grant's approval policy: which requests it matches, and
  whether those go through, wait for you, or are refused.

  `match` is what a person reads ("GET, HEAD on any path"); `tag` is what
  the proxy matches, against the tags `MDTClient.Sandbox.Describe` gives a
  request. `any` matches every request.
  """

  @enforce_keys [:id, :label, :match, :action, :tag]
  defstruct [:id, :label, :match, :action, :tag]

  @type action :: :allow | :ask | :deny

  @type t :: %__MODULE__{
          id: String.t(),
          label: String.t(),
          match: String.t(),
          action: action(),
          tag: String.t()
        }

  @actions [:allow, :ask, :deny]

  @doc "Every action a rule can take, most permissive first."
  @spec actions() :: [action()]
  def actions, do: @actions

  @doc "Whether this rule covers a request with these tags."
  @spec matches?(t(), [String.t()]) :: boolean()
  def matches?(%__MODULE__{tag: "any"}, _tags), do: true
  def matches?(%__MODULE__{tag: tag}, tags), do: tag in tags
end
