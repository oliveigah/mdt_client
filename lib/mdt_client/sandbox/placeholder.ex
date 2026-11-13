defmodule MDTClient.Sandbox.Placeholder do
  @moduledoc """
  A token grant's placeholder in a request's headers: finding it, and putting
  the real value in its place.

  The two are one module so they can't disagree: what `in?/2` finds is what
  `swap/3` replaces. A placeholder is long and random, so a plain substring
  is unambiguous. It is looked for in each header as sent, and inside a
  `Basic` credential, which is how git and `curl -u` send a password.
  Headers only: a placeholder in a URL or a body goes out as it is.
  """

  @type headers :: [{String.t(), String.t()}]

  @doc """
  Whether some header carries `placeholder`.

      iex> MDTClient.Sandbox.Placeholder.in?([{"authorization", "Bearer mdt_x"}], "mdt_x")
      true

      iex> basic = "Basic " <> Base.encode64("git:mdt_x")
      iex> MDTClient.Sandbox.Placeholder.in?([{"authorization", basic}], "mdt_x")
      true

      iex> MDTClient.Sandbox.Placeholder.in?([{"accept", "*/*"}], "mdt_x")
      false
  """
  @spec in?(headers(), String.t() | nil) :: boolean()
  def in?(headers, placeholder) when is_binary(placeholder) do
    Enum.any?(headers, fn {_name, value} ->
      String.contains?(value, placeholder) or String.contains?(basic(value) || "", placeholder)
    end)
  end

  def in?(_headers, nil), do: false

  @doc """
  The headers with `value` wherever `placeholder` was.

      iex> MDTClient.Sandbox.Placeholder.swap([{"authorization", "Bearer mdt_x"}], "mdt_x", "real")
      [{"authorization", "Bearer real"}]
  """
  @spec swap(headers(), String.t(), String.t()) :: headers()
  def swap(headers, placeholder, value) do
    Enum.map(headers, fn {name, header} ->
      case basic(header) do
        decoded when is_binary(decoded) ->
          if String.contains?(decoded, placeholder),
            do: {name, "Basic " <> Base.encode64(String.replace(decoded, placeholder, value))},
            else: {name, String.replace(header, placeholder, value)}

        nil ->
          {name, String.replace(header, placeholder, value)}
      end
    end)
  end

  defp basic(value) do
    with ["Basic", encoded] <- String.split(value, " ", parts: 2),
         {:ok, decoded} <- Base.decode64(String.trim(encoded)) do
      decoded
    else
      _ -> nil
    end
  end
end
