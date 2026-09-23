defmodule MDTClient.HttpClient.Core do
  @moduledoc """
  Executes HTTP client requests.

  Every function takes the username whose vault the history belongs to; that
  vault must be unlocked.
  """

  require Logger

  alias MDTClient.Accounts
  alias MDTClient.HttpClient.HistoryMetadata
  alias MDTClient.HttpClient.Resources

  @doc "Executes a `Req.Request` through Req's request pipeline and records it."
  @spec request(String.t(), Req.Request.t()) :: {:ok, Req.Response.t()} | {:error, Exception.t()}
  @spec request(String.t(), Req.Request.t(), HistoryMetadata.t() | map()) ::
          {:ok, Req.Response.t()} | {:error, Exception.t()}
  def request(username, %Req.Request{} = request, metadata \\ %{}) do
    {result, _identifier, _duration_ms} = request_recorded(username, request, metadata)
    result
  end

  @doc "Executes and records a request, returning its history ID and measured duration."
  @spec request_recorded(String.t(), Req.Request.t(), HistoryMetadata.t() | map()) ::
          {{:ok, Req.Response.t()} | {:error, Exception.t()}, pos_integer(), non_neg_integer()}
  def request_recorded(username, %Req.Request{} = request, metadata \\ %{}) do
    log_metadata = [user: Accounts.normalize(username), system: :http_client]
    method = request.method |> to_string() |> String.upcase()
    host = request.url.host

    Logger.info("request started method=#{method} host=#{inspect(host)}", log_metadata)
    started_at = DateTime.utc_now()
    result = Req.request(request)
    completed_at = DateTime.utc_now()

    metadata =
      metadata
      |> HistoryMetadata.new()
      |> HistoryMetadata.with_timing(started_at, completed_at)

    identifier = Resources.record(username, metadata, request, response_from(result))

    case result do
      {:ok, response} ->
        Logger.info(
          "request finished method=#{method} host=#{inspect(host)} status=#{response.status} duration_ms=#{metadata.duration_ms} history_id=#{identifier}",
          log_metadata
        )

      {:error, error} ->
        Logger.warning(
          "request failed method=#{method} host=#{inspect(host)} error=#{inspect(error.__struct__)} duration_ms=#{metadata.duration_ms} history_id=#{identifier}",
          log_metadata
        )
    end

    {result, identifier, metadata.duration_ms}
  end

  @doc "Adds a tag to a persisted request history entry."
  @spec add_tag(String.t(), pos_integer() | String.t(), String.t()) ::
          {:ok, Resources.entry()} | {:error, :not_found | :invalid_identifier}
  def add_tag(username, identifier, tag) when is_binary(tag) do
    update_metadata(username, identifier, &HistoryMetadata.add_tag(&1, tag))
  end

  @doc "Sets the user description for a persisted request history entry."
  @spec set_description(String.t(), pos_integer() | String.t(), String.t() | nil) ::
          {:ok, Resources.entry()} | {:error, :not_found | :invalid_identifier}
  def set_description(username, identifier, description)
      when is_binary(description) or is_nil(description) do
    update_metadata(username, identifier, &HistoryMetadata.set_description(&1, description))
  end

  @doc "Deletes a persisted request history entry."
  @spec delete(String.t(), pos_integer() | String.t()) ::
          {:ok, Resources.entry()} | {:error, :not_found | :invalid_identifier}
  def delete(username, identifier) do
    with {:ok, identifier} <- history_identifier(identifier),
         {:ok, entry} <- Resources.get(username, identifier),
         :ok <- Resources.delete(username, identifier) do
      {:ok, entry}
    else
      :error -> {:error, :not_found}
      :invalid_identifier -> {:error, :invalid_identifier}
    end
  end

  defp response_from({:ok, response}), do: response
  defp response_from({:error, error}), do: error

  defp update_metadata(username, identifier, update) do
    with {:ok, identifier} <- history_identifier(identifier),
         {:ok, {^identifier, metadata, request, response}} <- Resources.get(username, identifier) do
      metadata = metadata |> update.() |> HistoryMetadata.with_search_text(request, response)
      entry = {identifier, metadata, request, response}
      true = :ets.insert(Resources.table(username), entry)
      :ok = Resources.touch(username)

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
