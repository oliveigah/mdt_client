defmodule MDTClient.HttpClient.Core do
  @moduledoc """
  Executes HTTP client requests.
  """

  alias MDTClient.HttpClient.Resources
  alias MDTClient.HttpClient.HistoryMetadata

  @doc "Executes a `Req.Request` through Req's request pipeline and records it."
  @spec request(Req.Request.t()) :: {:ok, Req.Response.t()} | {:error, Exception.t()}
  @spec request(Req.Request.t(), HistoryMetadata.t() | map()) ::
          {:ok, Req.Response.t()} | {:error, Exception.t()}
  def request(%Req.Request{} = request, metadata \\ %{}) do
    started_at = DateTime.utc_now()
    result = Req.request(request)
    completed_at = DateTime.utc_now()

    Resources.record(
      metadata
      |> HistoryMetadata.new()
      |> HistoryMetadata.with_timing(started_at, completed_at),
      request,
      response_from(result)
    )

    result
  end

  @doc "Adds a tag to a persisted request history entry."
  @spec add_tag(pos_integer() | String.t(), String.t()) ::
          {:ok, Resources.entry()} | {:error, :not_found | :invalid_identifier}
  def add_tag(identifier, tag) when is_binary(tag) do
    update_metadata(identifier, &HistoryMetadata.add_tag(&1, tag))
  end

  @doc "Sets the user description for a persisted request history entry."
  @spec set_description(pos_integer() | String.t(), String.t() | nil) ::
          {:ok, Resources.entry()} | {:error, :not_found | :invalid_identifier}
  def set_description(identifier, description)
      when is_binary(description) or is_nil(description) do
    update_metadata(identifier, &HistoryMetadata.set_description(&1, description))
  end

  @doc "Deletes a persisted request history entry."
  @spec delete(pos_integer() | String.t()) ::
          {:ok, Resources.entry()} | {:error, :not_found | :invalid_identifier}
  def delete(identifier) do
    with {:ok, identifier} <- history_identifier(identifier),
         {:ok, entry} <- Resources.get(identifier),
         :ok <- Resources.delete(identifier) do
      {:ok, entry}
    else
      :error -> {:error, :not_found}
      :invalid_identifier -> {:error, :invalid_identifier}
    end
  end

  defp response_from({:ok, response}), do: response
  defp response_from({:error, error}), do: error

  defp update_metadata(identifier, update) do
    with {:ok, identifier} <- history_identifier(identifier),
         {:ok, {^identifier, metadata, request, response}} <- Resources.get(identifier) do
      metadata = metadata |> update.() |> HistoryMetadata.with_search_text(request, response)
      entry = {identifier, metadata, request, response}
      true = :ets.insert(Resources.table(), entry)

      {:ok, entry}
    else
      :error -> {:error, :not_found}
      :invalid_identifier -> {:error, :invalid_identifier}
    end
  end

  defp history_identifier(identifier) when is_integer(identifier) and identifier > 0,
    do: {:ok, identifier}

  defp history_identifier(identifier) when is_binary(identifier) do
    case Integer.parse(identifier) do
      {identifier, ""} when identifier > 0 -> {:ok, identifier}
      _invalid -> :invalid_identifier
    end
  end

  defp history_identifier(_identifier), do: :invalid_identifier
end
