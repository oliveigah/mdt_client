defmodule MDTClient.HttpClient.CurlTest do
  use ExUnit.Case, async: true

  alias MDTClient.HttpClient.Curl
  alias MDTClient.HttpClient.Utils

  describe "to_curl/1" do
    test "renders method, url, params, headers, auth and body" do
      request =
        Utils.new_request(%{
          method: "POST",
          url: "https://api.mdt.dev/v1/orders",
          params: [Utils.new_row("dry_run", "true"), Utils.new_row()],
          headers: [Utils.new_row("Content-Type", "application/json"), Utils.new_row()],
          body_type: "json",
          body: ~s({"sku": "MDT-PRO"}),
          auth_type: "bearer",
          auth_token: "tok_123"
        })

      command = Curl.to_curl(request)

      assert command =~ "curl --request POST"
      assert command =~ "--url 'https://api.mdt.dev/v1/orders?dry_run=true'"
      assert command =~ "--header 'Content-Type: application/json'"
      assert command =~ "--header 'Authorization: Bearer tok_123'"
      assert command =~ ~s(--data '{"sku": "MDT-PRO"}')
    end

    test "skips disabled rows and empty bodies" do
      request =
        Utils.new_request(%{
          url: "https://mdt.dev",
          headers: [%{Utils.new_row("X-Off", "1") | enabled: false}, Utils.new_row()],
          body_type: "json",
          body: ""
        })

      command = Curl.to_curl(request)

      refute command =~ "X-Off"
      refute command =~ "--data"
    end

    test "uses --user for basic auth and escapes quotes" do
      request =
        Utils.new_request(%{
          url: "https://mdt.dev",
          auth_type: "basic",
          auth_username: "dev",
          auth_password: "s3'cret"
        })

      assert Curl.to_curl(request) =~ ~S(--user 'dev:s3'\''cret')
    end
  end

  describe "from_curl/1" do
    test "reads a command copied out of devtools" do
      {:ok, attrs} =
        Curl.from_curl("""
        curl 'https://api.example.com/v1/users?page=2&per_page=10' \\
          -X PATCH \\
          -H 'accept: application/json' \\
          -H "authorization: Basic ZGV2OnMzY3JldA==" \\
          --data-raw '{"name":"Ada"}' \\
          --compressed -L
        """)

      assert attrs.method == "PATCH"
      assert attrs.url == "https://api.example.com/v1/users"
      assert attrs.body == ~s({"name":"Ada"})
      assert attrs.body_type == "json"
      assert attrs.editor_tab == "body"
      assert attrs.auth_type == "basic"
      assert attrs.auth_username == "dev"
      assert attrs.auth_password == "s3cret"
      assert rows(attrs.params) == [{"page", "2"}, {"per_page", "10"}, {"", ""}]
      assert rows(attrs.headers) == [{"accept", "application/json"}, {"", ""}]
    end

    test "defaults to POST when a body is given without a method" do
      {:ok, attrs} = Curl.from_curl("curl https://mdt.dev/hooks -d 'a=1' -d 'b=2'")

      assert attrs.method == "POST"
      assert attrs.body == "a=1&b=2"
      assert attrs.body_type == "form"
    end

    test "reads a bearer token into the auth tab" do
      {:ok, attrs} = Curl.from_curl(~s(curl https://mdt.dev -H "Authorization: Bearer tok_9"))

      assert attrs.auth_type == "bearer"
      assert attrs.auth_token == "tok_9"
      assert rows(attrs.headers) == [{"", ""}]
    end

    test "keeps an authorization header it cannot read" do
      {:ok, attrs} = Curl.from_curl(~s(curl https://mdt.dev -H "Authorization: Weird xyz"))

      refute Map.has_key?(attrs, :auth_type)
      assert rows(attrs.headers) == [{"Authorization", "Weird xyz"}, {"", ""}]
    end

    test "handles -u, attached methods and unknown flags" do
      {:ok, attrs} =
        Curl.from_curl("curl -XDELETE --retry 3 -u dev:secret https://api.mdt.dev/v1/orders/1")

      assert attrs.method == "DELETE"
      assert attrs.url == "https://api.mdt.dev/v1/orders/1"
      assert attrs.auth_type == "basic"
      assert attrs.auth_username == "dev"
    end

    test "round trips a request" do
      request =
        Utils.new_request(%{
          method: "PUT",
          url: "https://api.mdt.dev/v1/users/42",
          params: [Utils.new_row("verbose", "1"), Utils.new_row()],
          headers: [Utils.new_row("Accept", "application/json"), Utils.new_row()],
          body_type: "json",
          body: ~s({"name": "Ada"}),
          auth_type: "bearer",
          auth_token: "tok_123"
        })

      {:ok, attrs} = request |> Curl.to_curl() |> Curl.from_curl()

      assert attrs.method == request.method
      assert attrs.url == request.url
      assert attrs.body == request.body
      assert attrs.auth_token == request.auth_token
      assert rows(attrs.params) == rows(request.params)
      assert rows(attrs.headers) == rows(request.headers)
    end

    test "bundled switches do not swallow the flag after them" do
      {:ok, attrs} =
        Curl.from_curl("""
        curl -sS -X POST \\
           'https://internal.ume.com.br/credit/external-data-service/bvs_equifax/bvs_datalake' \\
           -H 'Content-Type: application/json' \\
           -H 'X-Cache-Max-Age-Seconds: 0' \\
           -d '{
             "documento": "<CPF_11_DIGITOS>",
             "origin": "UME_EOS26"
           }'
        """)

      assert attrs.method == "POST"

      assert attrs.url ==
               "https://internal.ume.com.br/credit/external-data-service/bvs_equifax/bvs_datalake"

      assert rows(attrs.headers) == [
               {"Content-Type", "application/json"},
               {"X-Cache-Max-Age-Seconds", "0"},
               {"", ""}
             ]

      assert attrs.body_type == "json"

      assert Jason.decode!(attrs.body) == %{
               "documento" => "<CPF_11_DIGITOS>",
               "origin" => "UME_EOS26"
             }
    end

    test "a short option takes its value from the same word or the next one" do
      {:ok, attrs} = Curl.from_curl("curl -sSLXPUT -Haccept:text/plain -k https://mdt.dev")

      assert attrs.method == "PUT"
      assert attrs.url == "https://mdt.dev"
      assert rows(attrs.headers) == [{"accept", "text/plain"}, {"", ""}]
    end

    test "switches never take the URL as their value" do
      for switch <- ~w(-s -L -k -i -v --compressed --insecure --location --fail-with-body) do
        assert {:ok, %{url: "https://mdt.dev/a"}} =
                 Curl.from_curl("curl #{switch} https://mdt.dev/a"),
               "#{switch} swallowed the URL"
      end
    end

    test "options that take a value skip it, even when it looks like a URL" do
      {:ok, attrs} =
        Curl.from_curl(
          "curl --proxy http://proxy.local:3128 -o out.json --retry 2 -m 45 https://mdt.dev/b"
        )

      assert attrs.url == "https://mdt.dev/b"
      assert attrs.timeout_ms == "60000"
    end

    test "reads shell quoting the way a shell does" do
      {:ok, attrs} =
        Curl.from_curl(~S"""
        curl "https://mdt.dev/q" --data-raw $'{"name":"O\'Neil","note":"a\nb"}' -H "X-Path: C:\temp \"x\""
        """)

      assert attrs.body == ~s({"name":"O'Neil","note":"a\nb"})
      assert rows(attrs.headers) == [{"X-Path", ~S(C:\temp "x")}, {"", ""}]
    end

    test "keeps an empty quoted value" do
      {:ok, attrs} = Curl.from_curl("curl -X POST -d '' https://mdt.dev")

      assert attrs.url == "https://mdt.dev"
      assert attrs.method == "POST"
    end

    test "stops at a pipe" do
      {:ok, attrs} = Curl.from_curl("curl -s https://mdt.dev/items | jq '.items'")

      assert attrs.url == "https://mdt.dev/items"
      assert attrs.method == "GET"
    end

    test "--json sends JSON and asks for it back" do
      {:ok, attrs} = Curl.from_curl(~s(curl --json '{"a":1}' https://mdt.dev))

      assert attrs.method == "POST"
      assert attrs.body_type == "json"
      assert rows(attrs.headers) == [{"Accept", "application/json"}, {"", ""}]
    end

    test "-G moves the data into the query string" do
      {:ok, attrs} =
        Curl.from_curl(
          "curl -G https://mdt.dev/search?lang=en -d q=elixir --data-urlencode 'tag=a b'"
        )

      assert attrs.method == "GET"
      assert attrs.body_type == "none"
      assert rows(attrs.params) == [{"lang", "en"}, {"q", "elixir"}, {"tag", "a b"}, {"", ""}]
    end

    test "reads the user agent, referer, cookies and bearer token options" do
      {:ok, attrs} =
        Curl.from_curl(
          "curl -A mdt/1.0 -e https://from.dev -b 'a=1; b=2' --oauth2-bearer tok_1 mdt.dev"
        )

      assert attrs.url == "http://mdt.dev"
      assert attrs.auth_type == "bearer"
      assert attrs.auth_token == "tok_1"

      assert rows(attrs.headers) == [
               {"User-Agent", "mdt/1.0"},
               {"Referer", "https://from.dev"},
               {"Cookie", "a=1; b=2"},
               {"", ""}
             ]
    end

    test "-I asks for HEAD" do
      assert {:ok, %{method: "HEAD"}} = Curl.from_curl("curl -I https://mdt.dev")
    end

    test "reports what it cannot parse" do
      assert {:error, "the command has to start with `curl`"} =
               Curl.from_curl("wget https://mdt.dev")

      assert {:error, "no URL found in the command"} = Curl.from_curl("curl -X POST")

      assert {:error, "the command has an unbalanced quote"} =
               Curl.from_curl("curl 'https://mdt.dev")

      assert {:error, "`-H` needs a value"} = Curl.from_curl("curl https://mdt.dev -H")

      assert {:error, "the PURGE method is not supported"} =
               Curl.from_curl("curl -X PURGE https://mdt.dev")
    end
  end

  defp rows(rows), do: Enum.map(rows, &{&1.key, &1.value})
end
