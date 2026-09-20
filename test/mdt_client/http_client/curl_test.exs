defmodule MDTClient.HttpClient.CurlTest do
  use ExUnit.Case, async: true

  alias MDTClient.HttpClient
  alias MDTClient.HttpClient.Curl

  describe "to_curl/1" do
    test "renders method, url, params, headers, auth and body" do
      request =
        HttpClient.new_request(%{
          method: "POST",
          url: "https://api.mdt.dev/v1/orders",
          params: [HttpClient.new_row("dry_run", "true"), HttpClient.new_row()],
          headers: [HttpClient.new_row("Content-Type", "application/json"), HttpClient.new_row()],
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
        HttpClient.new_request(%{
          url: "https://mdt.dev",
          headers: [%{HttpClient.new_row("X-Off", "1") | enabled: false}, HttpClient.new_row()],
          body_type: "json",
          body: ""
        })

      command = Curl.to_curl(request)

      refute command =~ "X-Off"
      refute command =~ "--data"
    end

    test "uses --user for basic auth and escapes quotes" do
      request =
        HttpClient.new_request(%{
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
        HttpClient.new_request(%{
          method: "PUT",
          url: "https://api.mdt.dev/v1/users/42",
          params: [HttpClient.new_row("verbose", "1"), HttpClient.new_row()],
          headers: [HttpClient.new_row("Accept", "application/json"), HttpClient.new_row()],
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

    test "reports what it cannot parse" do
      assert {:error, "the command has to start with `curl`"} =
               Curl.from_curl("wget https://mdt.dev")

      assert {:error, "no URL found in the command"} = Curl.from_curl("curl -X POST")

      assert {:error, "the command has an unbalanced quote"} =
               Curl.from_curl("curl 'https://mdt.dev")
    end
  end

  defp rows(rows), do: Enum.map(rows, &{&1.key, &1.value})
end
