defmodule MDTClient.Sandbox.Build do
  @moduledoc """
  One built image: what went in and what came out.

  `ref` is what microsandbox knows it by, `name:tag`. The Containerfile is
  kept as it was, since rebuilding it later gives other versions: going back
  means using the build, not the recipe.
  """

  @enforce_keys [:ref, :name, :tag, :built_at]
  defstruct [:ref, :name, :tag, :built_at, containerfile: "", versions: "", size: nil]

  @type t :: %__MODULE__{
          ref: String.t(),
          name: String.t(),
          tag: String.t(),
          built_at: DateTime.t(),
          containerfile: String.t(),
          versions: String.t(),
          size: non_neg_integer() | nil
        }
end
