defmodule MDTClient.MCP.SchemaTest do
  use ExUnit.Case, async: true

  alias MDTClient.MCP.Schema

  test "enforces conditional coordinates and positive dimensions at the indexed field path" do
    schema = %{
      "type" => "array",
      "items" => %{
        "type" => "object",
        "properties" => %{
          "type" => %{"enum" => ["arrow", "rectangle"]},
          "x1" => %{"type" => "number"},
          "width" => %{"type" => "number"}
        },
        "required" => ["type"],
        "allOf" => [
          %{
            "if" => %{"properties" => %{"type" => %{"const" => "arrow"}}},
            "then" => %{"required" => ["x1"]},
            "else" => %{
              "required" => ["width"],
              "properties" => %{"width" => %{"exclusiveMinimum" => 0}}
            }
          }
        ]
      }
    }

    assert :ok = Schema.validate([%{"type" => "arrow", "x1" => 0}], schema)
    assert :ok = Schema.validate([%{"type" => "rectangle", "width" => 0.5}], schema)

    assert {:error, "arguments[0].x1 is required"} =
             Schema.validate([%{"type" => "arrow"}], schema)

    assert {:error, "arguments[0].width must be greater than 0"} =
             Schema.validate([%{"type" => "rectangle", "width" => 0}], schema)

    assert {:error, _} = Schema.validate([%{"type" => "rectangle", "width" => -1}], schema)
  end

  test "combines every allOf constraint and handles null constants" do
    schema = %{
      "allOf" => [
        %{"type" => "number", "minimum" => 1},
        %{"maximum" => 3}
      ]
    }

    assert :ok = Schema.validate(2, schema)
    assert {:error, _} = Schema.validate(0, schema)
    assert {:error, _} = Schema.validate(4, schema)
    assert :ok = Schema.validate(nil, %{"const" => nil})
    assert {:error, _} = Schema.validate(false, %{"const" => nil})
  end

  test "validates dynamic header names against their additionalProperties schema" do
    schema = %{
      "type" => "object",
      "additionalProperties" => %{"type" => "array", "items" => %{"type" => "string"}}
    }

    assert :ok = Schema.validate(%{"x-demo" => ["one", "two"]}, schema)

    assert {:error, "arguments.x-demo must have type \"array\""} =
             Schema.validate(%{"x-demo" => "one"}, schema)

    assert {:error, "arguments.x-demo[0] must have type \"string\""} =
             Schema.validate(%{"x-demo" => [123]}, schema)
  end
end
