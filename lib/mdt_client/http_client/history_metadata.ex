defmodule MDTClient.HttpClient.HistoryMetadata do
  @moduledoc """
  User-facing and operational metadata for a recorded HTTP request.
  """

  @type t :: %__MODULE__{
          started_at: DateTime.t(),
          completed_at: DateTime.t(),
          duration_ms: non_neg_integer(),
          description: String.t() | nil,
          tags: [String.t()],
          search_text: String.t()
        }

  defstruct [
    :started_at,
    :completed_at,
    :duration_ms,
    description: nil,
    tags: [],
    search_text: ""
  ]

  @doc "Builds metadata with optional user-supplied descriptions and tags."
  @spec new(t() | map()) :: t()
  def new(%__MODULE__{} = metadata), do: metadata

  def new(attrs) when is_map(attrs) do
    now = DateTime.utc_now()

    %__MODULE__{
      started_at: Map.get(attrs, :started_at, now),
      completed_at: Map.get(attrs, :completed_at, now),
      duration_ms: Map.get(attrs, :duration_ms, 0),
      description: normalize_description(Map.get(attrs, :description)),
      tags: normalize_tags(Map.get(attrs, :tags, []))
    }
  end

  @doc "Sets the optional user description for a history entry."
  @spec set_description(t(), String.t() | nil) :: t()
  def set_description(%__MODULE__{} = metadata, description) do
    %{metadata | description: normalize_description(description)}
  end

  @doc "Adds a normalized tag to a history entry."
  @spec add_tag(t(), String.t()) :: t()
  def add_tag(%__MODULE__{} = metadata, tag) do
    %{metadata | tags: normalize_tags(metadata.tags ++ [tag])}
  end

  @doc false
  @spec with_timing(t(), DateTime.t(), DateTime.t()) :: t()
  def with_timing(%__MODULE__{} = metadata, started_at, completed_at) do
    %__MODULE__{
      metadata
      | started_at: started_at,
        completed_at: completed_at,
        duration_ms: DateTime.diff(completed_at, started_at, :millisecond)
    }
  end

  @doc false
  @spec with_search_text(t(), Req.Request.t(), Req.Response.t() | Exception.t()) :: t()
  def with_search_text(%__MODULE__{} = metadata, %Req.Request{} = request, response) do
    search_text =
      [
        metadata |> Map.from_struct() |> Map.delete(:search_text),
        request,
        response
      ]
      |> Enum.map(&inspect(&1, limit: :infinity, printable_limit: :infinity))
      |> Enum.join("\n")
      |> normalize_search_text()

    %{metadata | search_text: search_text}
  end

  @doc false
  @spec normalize_search_text(String.t()) :: String.t()
  def normalize_search_text(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  defp normalize_description(description) when is_binary(description) do
    case String.trim(description) do
      "" -> nil
      description -> description
    end
  end

  defp normalize_description(_description), do: nil

  defp normalize_tags(tags) when is_list(tags) do
    tags
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_tags(_tags), do: []
end
