defmodule MDTClient.Git.Tag do
  @moduledoc """
  A tag pointing at a commit.

  `target` is always the commit the tag resolves to, whether the tag is a
  lightweight reference to it or an annotated tag object that dereferences to
  it. `object` is what the reference itself names, which differs from `target`
  only for annotated tags.
  """

  @enforce_keys [:name, :full_name, :target, :object]
  defstruct [:name, :full_name, :target, :object, annotated?: false]

  @type t :: %__MODULE__{
          name: String.t(),
          full_name: String.t(),
          target: String.t(),
          object: String.t(),
          annotated?: boolean()
        }
end
