defmodule MDTClient.Sandbox.GraphQLTest do
  use ExUnit.Case, async: true

  alias MDTClient.Sandbox.GraphQL

  test "braces alone are one query" do
    assert [%{kind: "query", name: nil, fields: ["viewer"]}] =
             GraphQL.operations("{ viewer { login } }")
  end

  test "comments and strings are not read as operations" do
    document = ~S'''
    # mutation fake { deleteRepository }
    query Find($text: String = "mutation { y }") {
      search(text: """ } mutation z { deleteRepository } """) { id }
    }
    '''

    assert [%{kind: "query", name: "Find", fields: ["search"]}] = GraphQL.operations(document)
  end

  test "an alias is read through to its field, and a directive isn't one" do
    document =
      "mutation M { harmless: deleteRepository(input: {id: 1}) @skip(if: false) { id } other }"

    assert [%{kind: "mutation", name: "M", fields: ["deleteRepository", "other"]}] =
             GraphQL.operations(document)
  end

  test "fields behind fragments count as the operation's own" do
    document = """
    mutation M { ...Named ... on Mutation { b } ... @include(if: true) { c } }
    fragment Named on Mutation { a ...Deeper }
    fragment Deeper on Mutation { d }
    """

    assert [%{kind: "mutation", fields: ["a", "d", "b", "c"]}] = GraphQL.operations(document)
  end

  test "default values with braces don't end an operation's header" do
    document =
      "query Q($f: Filter = {a: {b: 1}}, $l: [Int] = [1, 2]) { items(filter: $f) { id } }"

    assert [%{kind: "query", name: "Q", fields: ["items"]}] = GraphQL.operations(document)
  end

  test "the operation a server would run: the named one, or the only one" do
    two = "query a { x } mutation b { y }"

    assert {:ok, %{kind: "mutation", name: "b"}} = GraphQL.selected(two, "b")
    assert {:ok, %{kind: "query", name: "a"}} = GraphQL.selected(two, "a")
    assert :error = GraphQL.selected(two, nil)
    assert :error = GraphQL.selected(two, "missing")
    assert :error = GraphQL.selected("query a { x } query a { y }", "a")
    assert {:ok, %{kind: "mutation"}} = GraphQL.selected("mutation { y }", nil)
    assert :error = GraphQL.selected("not graphql", nil)
  end

  test "the digest ignores spacing and comments, and nothing else" do
    one = "query Q { viewer { login } }"
    assert GraphQL.digest(one) == GraphQL.digest("# hello\nquery Q {\n  viewer { login }\n}\n")
    refute GraphQL.digest(one) == GraphQL.digest("query Q { viewer { email } }")
    refute GraphQL.digest(one) == GraphQL.digest("mutation Q { viewer { login } }")
  end
end
