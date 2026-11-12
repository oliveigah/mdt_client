defmodule MDTClient.Sandbox.RequestViewTest do
  use ExUnit.Case, async: true

  alias MDTClient.Sandbox.{Grant, RequestView}

  @placeholder "ghp_PLACEHOLDER0123456789"

  defp marks do
    RequestView.marks([
      %Grant{
        id: "github",
        name: "GitHub",
        kind: :token,
        placeholder: @placeholder,
        env: ["GH_TOKEN"]
      },
      %Grant{id: "my-api", name: "My API", kind: :token, placeholder: "mdt_OTHER"},
      %Grant{id: "vpn", name: "VPN", kind: :network}
    ])
  end

  defp request(attrs) do
    Map.merge(
      %{
        host: "api.github.com",
        method: "GET",
        path: "/user",
        headers: [{"host", "api.github.com"}, {"authorization", "token #{@placeholder}"}],
        body: ""
      },
      attrs
    )
  end

  # Runs a copied curl command with curl replaced by a function that prints
  # its arguments, one per line: what the shell would really pass.
  defp curl_args(command) do
    script = "curl() { printf '%s\\n' \"$@\"; }\nGH_TOKEN=real-token\n" <> command
    {output, 0} = System.cmd("bash", ["-c", script])
    String.split(output, "\n", trim: true)
  end

  test "each token grant's placeholder is marked by its name and a variable" do
    assert [
             %{variable: "GH_TOKEN", label: "GitHub"},
             %{variable: "TOKEN_MY_API", label: "My API"}
           ] = marks()
  end

  test "headers show the grant's name where the placeholder is, Basic decoded" do
    basic = "Basic " <> Base.encode64("x-access-token:#{@placeholder}")

    assert [
             {"host", [{:text, "api.github.com"}]},
             {"authorization", [{:text, "token "}, {:mark, "GitHub"}]},
             {"proxy-authorization",
              [{:text, "Basic (decoded) x-access-token:"}, {:mark, "GitHub"}]},
             {"cookie", [{:text, "a=1"}]}
           ] =
             RequestView.headers(
               request(%{
                 headers: [
                   {"host", "api.github.com"},
                   {"authorization", "token #{@placeholder}"},
                   {"proxy-authorization", basic},
                   {"cookie", "a=1"}
                 ]
               }),
               marks()
             )
  end

  test "bodies are shown for what they are" do
    json = ~s({"z":1,"a":{"b":[1,2]}})

    assert %{format: :json, text: text, complete?: true} =
             RequestView.body(request(%{body: json, headers: [{"content-length", "22"}]}))

    # Keys keep the order the agent sent.
    assert text =~ ~r/"z": 1,\s+"a"/

    graphql = Jason.encode!(%{query: "mutation M { x }", variables: %{id: 1}, operationName: "M"})
    assert %{format: :graphql, text: gql} = RequestView.body(request(%{body: graphql}))
    assert gql =~ "# operation M\nmutation M { x }\n\n# variables\n{\n  \"id\": 1\n}"

    form =
      request(%{
        body: "a=1&b=hello+world",
        headers: [{"content-type", "application/x-www-form-urlencoded"}]
      })

    assert %{format: :form, text: "a = 1\nb = hello world"} = RequestView.body(form)

    assert %{format: :text, text: "plain words"} =
             RequestView.body(request(%{body: "plain words"}))

    assert %{format: :none} = RequestView.body(request(%{}))

    assert %{format: :binary, text: dump} = RequestView.body(request(%{body: <<0, 1, 2, ?A>>}))
    assert dump =~ "00000000  00 01 02 41"
    assert dump =~ "...A"
  end

  test "git's pkt-lines are spelled out, the pack summed up" do
    line =
      "#{String.duplicate("0", 40)} #{String.duplicate("a", 40)} refs/heads/fix\0report-status\n"

    pkt = String.pad_leading(Integer.to_string(byte_size(line) + 4, 16), 4, "0") <> line
    body = pkt <> "0000" <> "PACK" <> <<0, 0, 0, 2>>

    assert %{format: :git, text: text} =
             RequestView.body(
               request(%{
                 body: body,
                 headers: [{"content-type", "application/x-git-receive-pack-request"}]
               })
             )

    assert text =~ "refs/heads/fix\n    capabilities: report-status"
    assert text =~ "[flush]\n[pack data, 8 bytes]"
  end

  test "chunked bodies are joined, and a cut body says so" do
    chunked = "5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n"

    assert %{format: :text, text: "hello world", complete?: true} =
             RequestView.body(
               request(%{body: chunked, headers: [{"transfer-encoding", "chunked"}]})
             )

    assert %{text: "hel", complete?: false} =
             RequestView.body(
               request(%{body: "5\r\nhel", headers: [{"transfer-encoding", "chunked"}]})
             )

    cut = request(%{method: "POST", body: "abc", headers: [{"content-length", "100000"}]})
    assert %{complete?: false, kept: 3, size: 100_000} = RequestView.body(cut)

    assert RequestView.curl(cut, marks()) =~
             "# The body isn't included: MDT keeps the first 3 bytes"

    assert RequestView.raw(cut, marks()) =~ "[cut: MDT keeps the first 3 bytes"
  end

  test "curl carries the request with your token's variable in place of the placeholder" do
    body = ~s({"title":"it's done"})

    request =
      request(%{
        method: "POST",
        path: "/repos/o/r/pulls?draft=1",
        headers: [
          {"host", "api.github.com"},
          {"authorization", "token #{@placeholder}"},
          {"content-type", "application/json"},
          {"content-length", "#{byte_size(body)}"}
        ],
        body: body
      })

    command = RequestView.curl(request, marks())
    refute command =~ @placeholder

    assert curl_args(command) == [
             "https://api.github.com/repos/o/r/pulls?draft=1",
             "-H",
             "authorization: token real-token",
             "-H",
             "content-type: application/json",
             "--data-raw",
             body
           ]

    basic = "Basic " <> Base.encode64("x-access-token:#{@placeholder}")

    assert curl_args(
             RequestView.curl(
               request(%{method: "DELETE", headers: [{"authorization", basic}]}),
               marks()
             )
           ) == ["https://api.github.com/user", "-X", "DELETE", "-u", "x-access-token:real-token"]
  end

  test "raw HTTP names the variable, and leaves binary bodies out" do
    raw = RequestView.raw(request(%{}), marks())
    assert raw == "GET /user HTTP/1.1\nhost: api.github.com\nauthorization: token ${GH_TOKEN}\n"

    binary = RequestView.raw(request(%{method: "POST", body: <<0, 159, 146, 150>>}), marks())
    assert binary =~ "[4 bytes of binary data, not included]"
  end
end
