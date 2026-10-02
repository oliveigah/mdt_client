defmodule MDTClient.MCP.Schema do
  @moduledoc "Validates the JSON Schema subset used by MDT's MCP tools."

  def validate(value, schema, path \\ "arguments") do
    with :ok <- validate_value(value, schema, path),
         :ok <- reduce(Map.get(schema, "allOf", []), &validate(value, &1, path)) do
      validate_conditional(value, schema, path)
    end
  end

  defp validate_value(value, schema, path) do
    cond do
      Map.has_key?(schema, "const") and value != schema["const"] ->
        {:error, "#{path} must be #{inspect(schema["const"])}"}

      Map.has_key?(schema, "enum") and value not in schema["enum"] ->
        {:error, "#{path} must be one of #{inspect(schema["enum"])}"}

      not type?(value, Map.get(schema, "type")) ->
        {:error, "#{path} must have type #{inspect(schema["type"])}"}

      is_map(value) ->
        validate_object(value, schema, path)

      is_list(value) ->
        validate_array(value, schema, path)

      is_binary(value) ->
        validate_string(value, schema, path)

      is_number(value) ->
        validate_number(value, schema, path)

      true ->
        :ok
    end
  end

  defp validate_conditional(value, %{"if" => condition} = schema, path) do
    branch = if validate(value, condition, path) == :ok, do: "then", else: "else"
    validate(value, Map.get(schema, branch, %{}), path)
  end

  defp validate_conditional(_value, _schema, _path), do: :ok

  defp validate_object(value, schema, path) do
    properties = Map.get(schema, "properties", %{})
    required = Map.get(schema, "required", [])
    missing = Enum.find(required, &(not Map.has_key?(value, &1)))
    unknown = Enum.find(Map.keys(value), &(not Map.has_key?(properties, &1)))

    cond do
      missing ->
        {:error, "#{path}.#{missing} is required"}

      unknown && schema["additionalProperties"] == false ->
        {:error, "#{path}.#{unknown} is not supported"}

      map_size(value) < Map.get(schema, "minProperties", 0) ->
        {:error, "#{path} must contain at least #{schema["minProperties"]} properties"}

      true ->
        reduce(value, fn {key, item} ->
          property = Map.get(properties, key, additional_schema(schema))
          validate(item, property, "#{path}.#{key}")
        end)
    end
  end

  defp additional_schema(%{"additionalProperties" => schema}) when is_map(schema), do: schema
  defp additional_schema(_schema), do: %{}

  defp validate_array(value, schema, path) do
    cond do
      length(value) > Map.get(schema, "maxItems", 5_000) ->
        {:error, "#{path} contains too many items"}

      length(value) < Map.get(schema, "minItems", 0) ->
        {:error, "#{path} contains too few items"}

      true ->
        value
        |> Enum.with_index()
        |> reduce(fn {item, index} ->
          validate(item, Map.get(schema, "items", %{}), "#{path}[#{index}]")
        end)
    end
  end

  defp validate_string(value, schema, path) do
    cond do
      String.length(value) > Map.get(schema, "maxLength", 1_000_000) ->
        {:error, "#{path} is too long"}

      String.length(value) < Map.get(schema, "minLength", 0) ->
        {:error, "#{path} is too short"}

      schema["pattern"] && not Regex.match?(Regex.compile!(schema["pattern"]), value) ->
        {:error, "#{path} has an invalid format"}

      true ->
        :ok
    end
  end

  defp validate_number(value, schema, path) do
    cond do
      Map.has_key?(schema, "exclusiveMinimum") and value <= schema["exclusiveMinimum"] ->
        {:error, "#{path} must be greater than #{schema["exclusiveMinimum"]}"}

      Map.has_key?(schema, "minimum") and value < schema["minimum"] ->
        {:error, "#{path} is below its minimum"}

      Map.has_key?(schema, "maximum") and value > schema["maximum"] ->
        {:error, "#{path} is above its maximum"}

      true ->
        :ok
    end
  end

  defp reduce(items, fun) do
    Enum.reduce_while(items, :ok, fn item, :ok ->
      case fun.(item) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp type?(value, types) when is_list(types), do: Enum.any?(types, &type?(value, &1))
  defp type?(value, "object"), do: is_map(value)
  defp type?(value, "array"), do: is_list(value)
  defp type?(value, "string"), do: is_binary(value)
  defp type?(value, "integer"), do: is_integer(value)
  defp type?(value, "number"), do: is_number(value)
  defp type?(value, "boolean"), do: is_boolean(value)
  defp type?(value, "null"), do: is_nil(value)
  defp type?(_value, nil), do: true
end
