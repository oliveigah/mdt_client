defmodule MDTClient.Sandbox.DescribeTest do
  use ExUnit.Case, async: true

  alias MDTClient.Sandbox.Describe

  defp pkt(line),
    do: ((byte_size(line) + 4) |> Integer.to_string(16) |> String.pad_leading(4, "0")) <> line

  defp request(attrs) do
    Map.merge(%{host: "github.com", method: "GET", path: "/", headers: [], body: ""}, attrs)
  end

  test "a push names its repository and ref updates, from the start of the pack" do
    zero = String.duplicate("0", 40)
    new = "8bd04e2" <> String.duplicate("a", 33)
    body = pkt("#{zero} #{new} refs/heads/fix\0report-status\n") <> "0000PACK..."

    described =
      Describe.request(
        request(%{
          method: "POST",
          path: "/oliveigah/klife.git/git-receive-pack",
          headers: [{"user-agent", "git/2.39.5"}],
          body: body
        })
      )

    assert described.tags == ["git_push"]
    assert described.title == "Push fix to oliveigah/klife"
    assert {"Ref", "refs/heads/fix  new at 8bd04e2"} in described.facts
    assert {"Client", "git/2.39.5"} in described.facts
    assert described.pattern == "POST github.com/oliveigah/klife.git/git-receive-pack"
  end

  test "GraphQL mutations and queries are told apart, and the agent's text is a claim" do
    mutation =
      Jason.encode!(%{
        query:
          "mutation CreatePR($input: CreatePullRequestInput!) { createPullRequest(input: $input) { pullRequest { url } } }",
        variables: %{input: %{title: "Fix the stall", body: "Retries per partition."}}
      })

    described =
      Describe.request(
        request(%{host: "api.github.com", method: "POST", path: "/graphql", body: mutation})
      )

    assert described.tags == ["graphql_mutation"]
    assert {"Operation", "mutation CreatePR"} in described.facts
    assert {"Title", "Fix the stall"} in described.claims
    refute Enum.any?(described.facts, fn {_, value} -> value == "Fix the stall" end)

    query = Jason.encode!(%{query: "{ viewer { login } }"})

    assert %{tags: ["graphql_query"]} =
             Describe.request(request(%{method: "POST", path: "/graphql", body: query}))
  end

  test "REST requests are reads or writes" do
    assert %{tags: ["read"]} = Describe.request(request(%{path: "/repos/o/r/pulls?state=open"}))

    assert %{tags: ["write"], pattern: "DELETE api.github.com/repos/o/r"} =
             Describe.request(
               request(%{host: "api.github.com", method: "DELETE", path: "/repos/o/r"})
             )
  end
end
