defmodule MDTClient.HttpClient.HistoryMetadata do
  @moduledoc """
  User-facing and operational metadata for a recorded HTTP request.
  """

  alias MDTClient.Search

  @searchable_body 32_768

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

  @doc """
  Rebuilds the text searches run against: the description, the tags, the
  method and URL, the status, and the headers and body going each way.

  A body is searchable as far as its first 32 KB, and only when it is text.
  What Req keeps beside it — options, steps, private data — is left out, so
  a search for a word like `retry` or `cache` finds the requests that
  mention it rather than every request.
  """
  @spec with_search_text(t(), Req.Request.t(), Req.Response.t() | Exception.t() | nil) :: t()
  def with_search_text(%__MODULE__{} = metadata, %Req.Request{} = request, response) do
    search_text =
      [
        metadata.description,
        metadata.tags,
        request.method |> to_string() |> String.upcase(),
        to_string(request.url),
        header_lines(request.headers),
        body_text(request.body),
        request.options
        |> Map.take([:params, :json, :form])
        |> Map.values()
        |> Enum.map(&body_text/1),
        response_text(response)
      ]
      |> List.flatten()
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join("\n")
      |> normalize_search_text()

    %{metadata | search_text: search_text}
  end

  @doc false
  @spec normalize_search_text(String.t()) :: String.t()
  def normalize_search_text(text) when is_binary(text), do: Search.normalize(text)

  defp response_text(%Req.Response{} = response) do
    [to_string(response.status), header_lines(response.headers), body_text(response.body)]
  end

  defp response_text(%{__exception__: true} = error), do: Exception.message(error)
  defp response_text(_response), do: nil

  defp header_lines(headers) do
    for {name, values} <- headers, value <- List.wrap(values), do: "#{name}: #{value}"
  end

  defp body_text(nil), do: nil

  defp body_text(body) when is_binary(body) do
    prefix =
      if byte_size(body) > @searchable_body,
        do: binary_part(body, 0, @searchable_body),
        else: body

    case :unicode.characters_to_binary(prefix) do
      text when is_binary(text) -> text
      # The cut landed inside a character, which goes too.
      {:incomplete, text, _rest} -> text
      # Not text at all: an image, an archive.
      {:error, _text, _rest} -> nil
    end
  end

  # Decoded JSON, a form as a keyword list: whatever it is, as it reads.
  defp body_text(body), do: inspect(body, limit: 500, printable_limit: @searchable_body)

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
