defmodule MDTClient.Sandbox.HostileTextTest do
  @moduledoc """
  Text and sizes the VM chooses, sent to break what shows them or to make it
  say something else: bytes that aren't UTF-8, characters that don't show,
  values of the wrong type, output without end. One part per way in. The
  proxy's own way in is in `guarantees_test.exs`, next to its harness.

  Written on 2026-11-13, when a path with one raw byte in it reached an
  approval's title, and from there the JSON every page is sent as.
  """
  use ExUnit.Case, async: true

  alias MDTClient.Sandbox

  alias MDTClient.Sandbox.{
    Channel,
    Describe,
    Dns,
    Guest,
    HostCommand,
    HostGit,
    Landing,
    PullRequest,
    PullStore,
    RequestView,
    Shown
  }

  alias MDTClient.Sandbox.Egress.Connection
  alias MDTClient.Vault.Store

  doctest MDTClient.Sandbox.Shown

  # Right-to-left override, zero-width space, escape.
  @rlo <<0x202E::utf8>>
  @zwsp <<0x200B::utf8>>
  @esc <<27>>

  # Every binary inside a term, however deep.
  defp texts(term) when is_binary(term), do: [term]
  defp texts(term) when is_list(term), do: Enum.flat_map(term, &texts/1)
  defp texts(term) when is_tuple(term), do: term |> Tuple.to_list() |> texts()
  defp texts(%_{} = struct), do: struct |> Map.from_struct() |> texts()
  defp texts(term) when is_map(term), do: term |> Map.to_list() |> texts()
  defp texts(_other), do: []

  # Safe to show and to send to a page: UTF-8, nothing hidden, and JSON.
  defp assert_shown(term) do
    for text <- texts(term) do
      assert String.valid?(text), "not UTF-8: #{inspect(text)}"
      assert Shown.hidden(text) == [], "hides #{inspect(Shown.hidden(text))}: #{inspect(text)}"
      assert {:ok, _} = Jason.encode(text)
    end
  end

  defp random_bytes(max), do: :rand.bytes(:rand.uniform(max + 1) - 1)

  # Bytes that are mostly text, with now and then something that isn't.
  defp noisy(max) do
    for _ <- 1..:rand.uniform(max), into: "" do
      case :rand.uniform(12) do
        1 -> <<:rand.uniform(256) - 1>>
        2 -> Enum.random([@rlo, @zwsp, @esc, "\r", <<0x2066::utf8>>, <<0xFEFF::utf8>>, "é", "я"])
        3 -> Enum.random(["/", "?", "=", "%", "{", "}", "\"", ":", " ", "\n"])
        _ -> <<Enum.random(?a..?z)>>
      end
    end
  end

  setup_all do
    :rand.seed(:exsss, {2026, 11, 13})
    :ok
  end

  describe "text made safe to show" do
    test "is UTF-8, hides nothing, and stays as it is when made safe again" do
      for _ <- 1..3_000 do
        raw = if :rand.uniform(2) == 1, do: random_bytes(200), else: noisy(120)
        shown = Shown.text(raw)

        assert_shown(shown)
        assert Shown.text(shown) == shown
      end
    end

    test "leaves ordinary text alone, in any language" do
      for text <- [
            "mix test --only vm",
            "olá, São Paulo\n\tfim",
            "日本語のコミット",
            "Привет",
            "naïve café"
          ] do
        assert Shown.text(text) == text
        assert Shown.hidden(text) == []
      end
    end

    test "writes out what doesn't show, where it stood" do
      assert Shown.text("abc" <> @rlo <> "def") == "abc\\u{202E}def"
      assert Shown.text("a" <> @zwsp <> "b") == "a\\u{200B}b"
      assert Shown.text("bold" <> @esc <> "[1m") == "bold\\u{1B}[1m"
      assert Shown.text("line\r\nline") == "line\nline"
      assert Shown.text("over\rwritten") == "over\\u{D}written"
      assert Shown.text(<<"caf", 0xE9, " ok">>) == "caf� ok"
    end
  end

  describe "a request's description" do
    @base %{host: "github.com", method: "GET", path: "/", headers: [], body: ""}

    test "shows all it holds, whatever bytes the request is made of" do
      zeros = String.duplicate("0", 40)
      ones = String.duplicate("1", 40)
      line = "#{zeros} #{ones} refs/heads/\xff\xfe#{@rlo}\0 report-status"
      pkt = String.pad_leading(Integer.to_string(byte_size(line) + 4, 16), 4, "0") <> line

      hostile = [
        %{@base | path: "/a/b/info/refs?service=%zz"},
        %{@base | path: "/repos/\xff"},
        %{@base | path: "/repos/" <> @rlo <> "txt.exe"},
        %{@base | host: "\xff.github.com"},
        %{@base | headers: [{"user-agent", "curl\xff\xfe"}]},
        %{@base | headers: [{"user-agent", "curl " <> @rlo <> "gnp.exe"}]},
        %{
          @base
          | method: "POST",
            path: "/repos/a/b/issues",
            body: Jason.encode!(%{title: "safe " <> @rlo <> " txet", body: "x" <> @zwsp <> "y"})
        },
        %{@base | method: "POST", path: "/a/b.git/git-receive-pack", body: pkt <> "0000"},
        %{@base | method: "POST", path: "/graphql", body: <<255, 254, 0, 1>>},
        %{
          @base
          | method: "POST",
            path: "/graphql",
            body:
              Jason.encode!(%{
                query: "query { repository(owner: $owner) { id } }",
                variables: %{owner: "octo" <> @zwsp <> "cat", name: @rlo <> "oper"}
              })
        },
        %{
          @base
          | method: "POST",
            path: "/graphql",
            body: Jason.encode!(%{query: String.duplicate("{a", 5_000)})
        }
      ]

      for request <- hostile, do: assert_shown(Describe.request(request))
    end

    test "is made for any bytes at all, without failing" do
      routes = ["/", "/graphql", "/a/b.git/git-receive-pack", "/a/b/info/refs?", "/repos/"]

      for _ <- 1..2_000 do
        request = %{
          host: Enum.random(["github.com", noisy(20)]),
          method: Enum.random(["GET", "POST", "PATCH"]),
          path: Enum.random(routes) <> noisy(40),
          headers: [{"user-agent", noisy(30)}, {"content-type", noisy(20)}],
          body:
            Enum.random([
              random_bytes(300),
              noisy(300),
              ~s({"query":") <> noisy(200) <> ~s("}),
              "00" <> noisy(100)
            ])
        }

        assert_shown(Describe.request(request))
      end
    end

    test "keeps apart, for an allowance, two requests that only look the same once shown" do
      a = Describe.request(%{@base | path: "/repos/\xff"})
      b = Describe.request(%{@base | path: "/repos/\xfe"})
      plain = Describe.request(%{@base | path: "/repos/a"})

      assert a.pattern != b.pattern
      assert plain.pattern == "GET github.com/repos/a"
    end
  end

  describe "the name a connection gives" do
    defp client_hello(name) do
      server_name = <<0, byte_size(name)::16, name::binary>>

      extension =
        <<0::16, byte_size(server_name) + 2::16, byte_size(server_name)::16, server_name::binary>>

      hello =
        <<3, 3, 0::256, 0, 2::16, 0x13, 0x01, 1, 0, byte_size(extension)::16, extension::binary>>

      handshake = <<1, byte_size(hello)::24, hello::binary>>
      <<0x16, 3, 1, byte_size(handshake)::16, handshake::binary>>
    end

    test "is taken when it is a host name" do
      assert Connection.sni(client_hello("API.GitHub.com")) == "api.github.com"
      assert Connection.sni(client_hello("xn--bcher-kva.example")) == "xn--bcher-kva.example"
      assert Connection.sni(client_hello("_dmarc.example.com")) == "_dmarc.example.com"
    end

    test "is no name when it is anything else, so nothing is read or logged under it" do
      for name <- [
            "\xff.github.com",
            "git" <> @rlo <> "hub.com",
            "github.com\0.evil.test",
            "github.com/path",
            "github.com evil.test",
            "bücher.example",
            ".github.com",
            "github.com.",
            String.duplicate("a", 300)
          ] do
        assert Connection.sni(client_hello(name)) == nil, inspect(name)
      end
    end
  end

  describe "a name asked of DNS" do
    defp question(labels) do
      name = for label <- labels, into: "", do: <<byte_size(label), label::binary>>
      <<0x12, 0x34, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, name::binary, 0, 0, 1, 0, 1>>
    end

    test "is read when it is visible ASCII" do
      assert Dns.question(question(["_acme-challenge", "Example", "com"])) ==
               {:ok, "_acme-challenge.example.com", "A"}
    end

    test "is not answered, and so not logged, when a label is anything else" do
      for label <- ["\xff\xfe", "a" <> @rlo <> "b", "a b", "tab\there", "bücher", "a" <> @zwsp] do
        assert Dns.question(question([label, "example", "com"])) == :error, inspect(label)
      end
    end
  end

  describe "an ask from the VM" do
    test "carries text, whole numbers and yes or no; anything else in it is nothing" do
      line =
        Jason.encode!(%{
          command: "request",
          grant: %{"a" => 1},
          reason: ["a", "list"],
          minutes: 1.5,
          wait: 30,
          need: nil,
          agent: "Claude" <> @rlo <> "edoC",
          thread: "fix\r\nthe " <> @zwsp <> "bug",
          flag: true
        })

      ask = Channel.read(line)

      assert ask["command"] == "request"
      assert ask["grant"] == nil
      assert ask["reason"] == nil
      assert ask["minutes"] == nil
      assert ask["need"] == nil
      assert ask["wait"] == 30
      assert ask["flag"] == true
      assert ask["agent"] == "Claude\\u{202E}edoC"
      assert_shown(ask)
    end

    test "keeps a script exactly as it was sent, for the check that refuses it" do
      script = "echo hi" <> @rlo <> "\r\n"
      ask = Channel.read(Jason.encode!(%{command: "run", script: script, reason: "r"}))
      assert ask["script"] == script
    end

    test "is unreadable when it isn't a JSON object naming a command" do
      for line <- ["", "not json", "[1,2]", ~s({"command": 5}), ~s({"reason": "x"}), <<255, 254>>] do
        assert Channel.read(line) == :unreadable
      end
    end

    test "with values of the wrong type gets a refusal, and the sandbox goes on" do
      %{username: username} = MDTClient.VaultHelpers.unlocked_identity("hostile")
      server = GenServer.whereis(Store.via(MDTClient.Sandbox.Server, username))

      {:ok, grant} =
        Sandbox.create_grant(username, %{
          "kind" => "command",
          "name" => "shell",
          "purpose" => "Run commands on this machine"
        })

      {:ok, _} = Sandbox.turn_on(username, grant.id, :until_off, :ask)

      # Straight at the server, as if the channel had let them through.
      junk = [%{"a" => 1}, ["x"], 1.5, 7, true, nil, <<255>>]

      for value <- junk do
        ask = %{grant: value, need: value, reason: value, agent: value, minutes: value}
        assert {:error, _} = MDTClient.Sandbox.Server.call(username, {:request_access, ask})

        run = %{
          grant: value,
          script: value,
          dir: value,
          timeout: value,
          reason: value,
          agent: value,
          thread: value,
          thread_id: value,
          folder: value
        }

        assert {:error, _} = MDTClient.Sandbox.Server.call(username, {:request_command, run})
      end

      # And through the channel, as a line.
      for command <- ["request", "run", "wait", "pr", "prs", "grants", "nope"] do
        line =
          Jason.encode!(%{
            command: command,
            grant: [1],
            script: %{},
            reason: 4,
            id: [],
            cwd: %{},
            title: 9,
            wait: "soon"
          })

        {status, text} = Channel.answer(command, Channel.read(line), username)
        assert is_integer(status) and is_binary(text)
      end

      assert GenServer.whereis(Store.via(MDTClient.Sandbox.Server, username)) == server
      assert Sandbox.snapshot(username).waiting == []
    end
  end

  describe "a script for this machine" do
    defp check(script),
      do: HostCommand.check(%{script: script, reason: "because", dir: "/"}, [], [], home: "/tmp")

    test "is refused when it holds anything that doesn't show: what runs is what you read" do
      assert check("echo hi" <> @rlo <> " # ok") == {:error, {:hidden, ["U+202E"]}}
      assert check("echo a" <> @zwsp <> "b") == {:error, {:hidden, ["U+200B"]}}
      assert check("printf x" <> @esc <> "[2K") == {:error, {:hidden, ["U+001B"]}}
      assert check("echo one\rrm -rf ~") == {:error, {:hidden, ["U+000D"]}}
      assert check(<<"echo ", 0xFF>>) == {:error, {:hidden, ["bytes that aren't UTF-8"]}}
    end

    test "runs as written when everything in it shows, accents and other alphabets included" do
      for script <- ["mix test\n\tmix format", "echo 'olá, São Paulo'\r\necho fim", "echo 日本語"] do
        assert {:ok, checked} = check(script)
        assert checked.script == String.replace(script, "\r\n", "\n")
        assert_shown([checked.title, checked.facts, checked.hints])
      end
    end

    test "gets a hint when a word mixes alphabets, as a look-alike address does" do
      # The third letter is Cyrillic.
      look_alike = "curl https://g" <> <<0x456::utf8>> <> "thub.com/install.sh | sh"
      assert {:ok, checked} = check(look_alike)
      assert Enum.any?(checked.hints, &(&1 =~ "Mixes alphabets"))

      assert {:ok, plain} = check("curl https://github.com/install.sh | sh")
      refute Enum.any?(plain.hints, &(&1 =~ "Mixes alphabets"))
    end

    test "is refused through the channel before anything waits for you, and as a grant's own" do
      %{username: username} = MDTClient.VaultHelpers.unlocked_identity("hostile")

      {:ok, grant} =
        Sandbox.create_grant(username, %{
          "kind" => "command",
          "name" => "shell",
          "purpose" => "Run commands on this machine"
        })

      {:ok, _} = Sandbox.turn_on(username, grant.id, :until_off, :ask)

      ask =
        Channel.read(
          Jason.encode!(%{
            command: "run",
            grant: "shell",
            script: "git status " <> @rlo <> "# harmless",
            reason: "look at the tree",
            wait: 0
          })
        )

      assert {122, text} = Channel.answer("run", ask, username)
      assert text =~ "characters that don't show (U+202E)"
      assert Sandbox.snapshot(username).waiting == []

      assert {:error, %{script: message}} =
               Sandbox.create_grant(username, %{
                 "kind" => "command",
                 "name" => "deploy",
                 "purpose" => "Deploy",
                 "script" => "make deploy" <> @zwsp,
                 "dir" => System.tmp_dir!()
               })

      assert message =~ "U+200B"
    end
  end

  describe "a held request, as you read and copy it" do
    test "shows all it holds: headers, body, the HTTP text and the curl command" do
      request = %{
        host: "api.github.com",
        method: "POST",
        path: "/repos/a/b/issues",
        headers: [
          {"host", "api.github.com"},
          {"user-agent", "curl\xff " <> @rlo <> "gnp"},
          {"x-note", "a" <> @esc <> "]0;title" <> <<7>>},
          {"content-type", "application/json"}
        ],
        body: Jason.encode!(%{title: "safe " <> @rlo <> "txet", body: "x" <> @zwsp <> "y"})
      }

      assert_shown(RequestView.headers(request, []))
      assert_shown(RequestView.body(request))
      assert_shown(RequestView.raw(request, []))
      assert_shown(RequestView.curl(request, []))
      assert_shown(RequestView.url(request))
      assert RequestView.curl(request, []) =~ "\\u{202E}"
    end
  end

  describe "a pull request" do
    @me [
      {"GIT_AUTHOR_NAME", "Someone"},
      {"GIT_AUTHOR_EMAIL", "someone@example.test"},
      {"GIT_COMMITTER_NAME", "Someone"},
      {"GIT_COMMITTER_EMAIL", "someone@example.test"}
    ]

    defp git(dir, args) do
      case System.cmd("git", ["-C", dir | args],
             env: @me ++ Guest.git_env(),
             stderr_to_stdout: true
           ) do
        {output, 0} -> output
        {output, status} -> flunk("git #{Enum.join(args, " ")} exited #{status}: #{output}")
      end
    end

    # Your repository, MDT's store for it, and the agent's clone in a folder
    # standing in for the VM, on a branch of its own.
    defp repository do
      base = Path.join(System.tmp_dir!(), "hostile-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(base) end)
      repo = Path.join(base, "host/app")
      File.mkdir_p!(repo)
      git(repo, ["init", "-q", "-b", "master"])
      File.write!(Path.join(repo, "a.txt"), "one\n")
      git(repo, ["add", "--all"])
      git(repo, ["commit", "-q", "-m", "first"])

      vm = Path.join(base, "vm")
      File.mkdir_p!(vm)
      clone = Path.join(vm, "app")
      {_, 0} = System.cmd("git", ["clone", "-q", repo, clone], env: Guest.git_env())
      git(clone, ["checkout", "-q", "-b", "task"])

      store = PullStore.path(Path.join(base, "sandbox"), repo)
      :ok = PullStore.ensure(store, repo)
      %{repo: repo, guest: Guest.local(vm), clone: clone, store: store}
    end

    defp open(context, opts \\ []) do
      git(context.clone, ["add", "--all"])
      git(context.clone, ["commit", "-q", "-m", Keyword.get(opts, :message, "work")])
      folder = Path.join(context.clone, ".git")
      limit = Keyword.get(opts, :size_limit_mib, 1024)

      with {:ok, head} <-
             PullStore.receive(context.store, context.guest, folder, "task", 1, limit) do
        {:ok,
         %PullRequest{
           id: 1,
           title: "The work",
           repo: context.repo,
           base: "master",
           source: %{folder: folder, top: context.clone, branch: "task"},
           head: head,
           opened_at: DateTime.utc_now()
         }}
      end
    end

    test "shows all it holds: file names, commit messages and the diff" do
      context = repository()
      File.write!(Path.join(context.clone, <<"caf", 0xE9, ".txt">>), "latin-1 name\n")
      File.write!(Path.join(context.clone, "safe" <> @rlo <> "txt.sh"), "echo hi\n")
      File.write!(Path.join(context.clone, "latin1.txt"), <<"caf", 0xE9, " ", 0xFF, "\n">>)

      File.write!(
        Path.join(context.clone, "screen.txt"),
        "clear" <> @esc <> "[2J\r\n" <> @zwsp <> "\n"
      )

      assert {:ok, pull} = open(context, message: "fix " <> @rlo <> "kcah a ton")

      assert {:ok, facts} = PullRequest.facts(context.store, pull)
      assert length(facts.files) == 4
      assert_shown(facts)
      assert Enum.any?(facts.commits, &(&1.subject =~ "\\u{202E}"))

      assert {:ok, diff} = PullRequest.diff(context.store, pull, facts.merge_base)
      assert_shown(diff)
      assert length(diff.files) == 4

      assert Enum.any?(diff.files, fn file ->
               Enum.any?(file.hunks, fn hunk ->
                 Enum.any?(hunk.lines, &(&1.text =~ "\\u{1B}[2J"))
               end)
             end)

      # And it still comes in whole, under the names it has.
      assert {:ok, _} = PullStore.copy_into(context.store, context.repo, 1)
      assert {:ok, _undo} = Landing.bring(context.repo, 1, pull.head, false)
      assert File.read!(Path.join(context.repo, <<"caf", 0xE9, ".txt">>)) == "latin-1 name\n"
    end

    test "has only the start of a long diff read, and says so" do
      context = repository()

      File.write!(
        Path.join(context.clone, "big.txt"),
        String.duplicate("a line of text\n", 200_000)
      )

      assert {:ok, pull} = open(context)
      assert {:ok, facts} = PullRequest.facts(context.store, pull)

      assert {:ok, %{files: [big], cut?: true}} =
               PullRequest.diff(context.store, pull, facts.merge_base)

      assert big.truncated?
      assert big.hunks |> Enum.map(&length(&1.lines)) |> Enum.sum() <= 6_000
    end

    test "is refused when it brings more than the limit, and leaves nothing of it behind" do
      context = repository()

      File.write!(
        Path.join(context.clone, "blob.bin"),
        :crypto.strong_rand_bytes(3 * 1024 * 1024)
      )

      refs = git(context.repo, ["for-each-ref"])

      assert open(context, size_limit_mib: 1) == {:error, :too_large}
      assert PullRequest.explain(:too_large) =~ "more than 1 GiB"
      assert git(context.repo, ["for-each-ref"]) == refs
      assert Path.wildcard(Path.join(context.store, "objects/**/tmp_*")) == []

      # Under the limit, the same branch arrives.
      File.write!(Path.join(context.clone, "note.txt"), "more\n")
      assert {:ok, _pull} = open(context, size_limit_mib: 16)
    end
  end

  describe "what git prints" do
    test "is read up to a limit: past it is an error, or the start when it is only shown" do
      repo = Path.join(System.tmp_dir!(), "hostile-git-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(repo) end)
      File.mkdir_p!(repo)
      {_, 0} = System.cmd("git", ["-C", repo, "init", "-q"])
      File.write!(Path.join(repo, "big.txt"), String.duplicate("0123456789abcdef", 4_096))
      {id, 0} = System.cmd("git", ["-C", repo, "hash-object", "-w", "big.txt"])
      id = String.trim(id)

      assert {:ok, whole} = HostGit.run(repo, ["cat-file", "-p", id])
      assert byte_size(whole) == 65_536
      assert {:ok, ^whole} = HostGit.run(repo, ["cat-file", "-p", id], max: 65_536)

      assert {:error, message} = HostGit.run(repo, ["cat-file", "-p", id], max: 2_048)
      assert message == "git cat-file printed more than 2 KiB"
      assert {:cut, start} = HostGit.run(repo, ["cat-file", "-p", id], max: 1_000, cut: true)
      assert start == binary_part(whole, 0, 1_000)

      # A failure's words are shown, so they are made safe.
      assert {:error, text} = HostGit.run(repo, ["rev-parse", "no" <> @rlo <> "such"])
      assert_shown(text)

      assert {:ok, _} =
               HostGit.run(repo, ["merge-base", "--is-ancestor", id, id], ok: [0, 1, 128])
    end
  end
end
